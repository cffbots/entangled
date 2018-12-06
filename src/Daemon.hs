module Daemon
    ( runSession ) where

import System.Directory
import Control.Concurrent.Chan

import qualified System.INotify as INotify
import qualified Data.ByteString as B
import Data.ByteString.Char8 (pack, unpack)

import qualified Data.Map as M
import Data.List
import Data.Either

import Control.Monad.Reader
import Control.Monad.State

import Lens.Micro.Platform

import Model
import Config
import Tangle
import Untangle
import Parser

type Message = String

data FileType = SourceFile | TargetFile

data Event = WriteEvent FileType FilePath
           | DebugEvent Message

-- ========================================================================= --
-- Session                                                                   --
-- ========================================================================= --

data Session = Session
    { _sourceData     :: M.Map FilePath [Content]
    , _referenceMap   :: ReferenceMap
    , _watches        :: M.Map FilePath INotify.WatchDescriptor
    , inotifyInstance :: INotify.INotify
    , _eventChannel   :: Chan Event
    }

type TangleM = StateT Session (ReaderT Config IO)

sourceData :: Lens' Session (M.Map FilePath [Content])
sourceData = lens _sourceData (\s n -> s { _sourceData = n })

referenceMap :: Lens' Session ReferenceMap
referenceMap = lens _referenceMap (\s n -> s { _referenceMap = n })

watches :: Lens' Session (M.Map FilePath INotify.WatchDescriptor)
watches = lens _watches (\s n -> s { _watches = n })

eventChannel :: Lens' Session (Chan Event)
eventChannel = lens _eventChannel (\s n -> s { _eventChannel = n })

setReferenceMap :: Monad m => ReferenceMap -> StateT Session m ()
setReferenceMap r = modify (set referenceMap r)

addFileContent :: Monad m => FilePath -> [Content] -> StateT Session m ()
addFileContent f c = modify (over sourceData (M.insert f c))

updateReferenceMap :: Monad m => (ReferenceMap -> ReferenceMap) -> StateT Session m ()
updateReferenceMap f = modify (over referenceMap f)

getDocument :: Monad m => FilePath -> StateT Session m (Maybe Document)
getDocument p = do
    content <- use $ sourceData . to (M.lookup p)
    refs    <- use referenceMap
    return $ Document refs <$> content

listAllTargetFiles :: Monad m => StateT Session m [FilePath]
listAllTargetFiles = map referenceName . filter isFileReference . M.keys <$> use referenceMap

listAllSourceFiles :: Monad m => StateT Session m [FilePath]
listAllSourceFiles = use $ sourceData . to M.keys

-- ========================================================================= --
-- Tangling                                                                  --
-- ========================================================================= --

tryReadFile :: FilePath -> IO (Maybe String)
tryReadFile f = do
    exists <- doesFileExist f
    if exists
        then Just <$> readFile f
        else return Nothing

writeFileOrWarn :: Show a => FilePath -> Either a String -> IO ()
writeFileOrWarn filename (Left error)
    = putStrLn $ "Error tangling '" ++ filename ++ "': " ++ show error
writeFileOrWarn filename (Right text) = do
    oldText <- tryReadFile filename
    when (oldText /= Just text) $ do
        putStrLn $ "Overwriting '" ++ filename ++ "'"
        writeFile filename text

tangleTargets :: TangleM ()
tangleTargets = do
    refs <- use referenceMap
    fileMap <- lift $ tangleAnnotated refs
    liftIO $ mapM_ (uncurry writeFileOrWarn) (M.toList fileMap)

-- ========================================================================= --
-- Loading                                                                   --
-- ========================================================================= --
    
loadSourceFile :: FilePath -> ReaderT Config IO (Either TangleError Document)
loadSourceFile f = do
    source  <- liftIO $ readFile f
    parseMarkdown f source

addSourceFile :: FilePath -> TangleM ()
addSourceFile f = do
    source  <- liftIO $ readFile f
    refs    <- use referenceMap
    doc'    <- lift $ parseMarkdown' refs f source
    case doc' of
        Left err -> liftIO $ putStrLn $ "Error loading '" ++ f ++ "': "
                        ++ show err
        Right (Document r c) -> do
            setReferenceMap r
            addFileContent f c

updateFromSource :: FilePath -> TangleM ()
updateFromSource fp = do
    doc' <- lift $ loadSourceFile fp
    case doc' of
        Left err -> liftIO $ putStrLn $ "Error loading '" ++ fp ++ "': " ++ show err
        Right (Document r c) -> do
            modifying referenceMap (M.union r)
            modifying sourceData (M.insert fp c)

-- ========================================================================= --
-- Untangle                                                                  --
-- ========================================================================= --

untangleTarget :: FilePath -> ReaderT Config IO (Either TangleError ReferenceMap)
untangleTarget f = liftIO (readFile f) >>= untangle f

getCodeBlock :: Monad m => ReferenceID -> StateT Session m (Maybe CodeBlock)
getCodeBlock id = use $ referenceMap . to (M.lookup id)

updateCodeBlock :: ReferenceID -> CodeBlock -> TangleM ()
updateCodeBlock r c = do
    old' <- getCodeBlock r
    case old' of
        Nothing -> liftIO $ putStrLn $ "  Error: code block " ++ show r ++ " not present."
        Just old -> when (old /= c) $ do
            liftIO $ putStrLn $ "  updating " ++ show r
            updateReferenceMap $ M.insert r c

updateFromTarget :: FilePath -> TangleM ()
updateFromTarget f = do
    refs' <- lift $ untangleTarget f
    case refs' of
        Left err -> liftIO $ putStrLn $ "Error updating from '" ++ f ++ "': "
                        ++ show err
        Right refs -> do
            liftIO $ putStrLn $ "Updating from '" ++ f
            mapM_ (uncurry updateCodeBlock) (M.toList refs)

-- ========================================================================= --
-- Stitching                                                                 --
-- ========================================================================= --

stitchSourceFile :: FilePath -> TangleM ()
stitchSourceFile f = do
    doc' <- getDocument f
    case doc' of
        Nothing  -> return ()
        Just doc -> liftIO $ writeFile f (stitchText doc)
    
stitchSources :: TangleM ()
stitchSources = do
    srcs <- listAllSourceFiles
    mapM_ stitchSourceFile srcs

-- ========================================================================= --
-- Watching                                                                  --
-- ========================================================================= --

passEvent :: Chan Event -> Event -> INotify.Event -> IO ()
passEvent c e _ = writeChan c e

addWatch :: FileType -> FilePath -> TangleM ()
addWatch t p = do
    inotify' <- gets inotifyInstance
    channel  <- use eventChannel
    wd <- liftIO $ INotify.addWatch inotify' [INotify.Modify] (pack p)
                                    (passEvent channel (WriteEvent t p))
    modify $ over watches (M.insert p wd)

removeWatch :: FilePath -> TangleM ()
removeWatch p = do
    wd' <- use $ watches . to (M.lookup p)
    case wd' of
        Nothing -> liftIO $ putStrLn $ "Warning: can't remove watch on " ++ p ++ "."
        Just wd -> do
            liftIO $ INotify.removeWatch wd
            modify $ over watches (M.delete p)

-- ========================================================================= --
-- Main interface                                                            --
-- ========================================================================= --

mainLoop :: [Event] -> TangleM ()

mainLoop [] = return ()

mainLoop (WriteEvent SourceFile fp : xs) = do
    mapM_ removeWatch =<< listAllTargetFiles
    updateFromSource fp
    tangleTargets
    mapM_ (addWatch TargetFile) =<< listAllTargetFiles
    mainLoop xs

mainLoop (WriteEvent TargetFile fp : xs) = do
    mapM_ removeWatch =<< listAllSourceFiles
    updateFromTarget fp
    stitchSources
    mapM_ (addWatch SourceFile) =<< listAllSourceFiles
    mainLoop xs

mainLoop (DebugEvent msg : xs)   = do
    liftIO $ putStrLn $ "Debug: " ++ msg
    mainLoop xs

startSession :: [FilePath] -> TangleM ()
startSession fs = do
    mapM_ addSourceFile fs
    tangleTargets
    mapM_ (addWatch SourceFile) =<< listAllSourceFiles
    mapM_ (addWatch TargetFile) =<< listAllTargetFiles
    eventList' <- use $ eventChannel . to getChanContents
    eventList  <- liftIO eventList'
    mainLoop eventList

runSession :: Config -> [FilePath] -> IO ()
runSession cfg fs = do
    inotify <- liftIO INotify.initINotify
    channel <- newChan
    let session = Session M.empty M.empty M.empty inotify channel
    runReaderT (runStateT (startSession fs) session) cfg
    liftIO $ INotify.killINotify inotify
