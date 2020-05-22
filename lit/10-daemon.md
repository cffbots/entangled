# The Daemon

The Entangled daemon does the following:

* Never crash
* Monitor markdown files, tangle when written to
* Monitor target files, stitch when written to
* Pretty print events

``` {.haskell file=src/Daemon.hs}
<<daemon>>
```

## Strategy

``` {.haskell #daemon}
module Daemon where
{-# LANGUAGE NoImplicitPrelude #-}
-- import RIO

import Prelude hiding (writeFile, readFile)

<<daemon-imports>>

<<daemon-events>>
<<daemon-session>>
<<daemon-loading>>
<<daemon-writing>>
<<daemon-watches>>
<<daemon-main-loop>>
<<daemon-start>>
```

``` {.haskell #daemon-imports}
<<import-text>>
import qualified Data.Text.IO as T.IO 
<<import-map>>
import TextUtil (tshow, unlines')
```

Using lenses we build a `Session` record. In combination with the `State` monad (and a `Reader Config`, and `IO`) we can manage the Entangled Daemon.

### FSNotify

We use `System.FSNotify` to setup watches on the files.

``` {.haskell #daemon-imports}
import qualified System.FSNotify as FSNotify
```

The watches are set to trigger events of type `Event`.

``` {.haskell #daemon-events}
data DaemonState
    = Idle
    | Tangling
    | Stitching
    deriving (Show, Eq)

data Event
    = WriteSource FilePath
    | WriteTarget FilePath
    | DebugEvent Text
    deriving (Show)
```

### Session

``` {.haskell #daemon-imports}
import Database.SQLite.Simple

import Document
import Config
import Database hiding (db)
import Tangle (parseMarkdown, expandedCode, Annotator, annotateComment')
import Comment
import Stitch (stitch)
import Transaction
import FileIO

import qualified Data.Text.Prettyprint.Doc as P
import qualified Console
import Console (Doc, msgWrite, msgCreate, msgDelete)

import Control.Concurrent.Chan
import Control.Concurrent
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.RWS
import Control.Monad.IO.Class
import Control.Monad.Writer
import Control.Monad.Catch
import Control.Monad.Logger
```

``` {.haskell #daemon-session}
data Session = Session
    { watches       :: [FSNotify.StopListening]
    , manager       :: FSNotify.WatchManager
    , eventChannel  :: Chan Event
    , daemonState   :: MVar DaemonState
    , sqlite        :: Connection
    -- , config        :: Config
    }

db :: ( MonadIO m, MonadState Session m )
   => SQL a -> m a
db x = do
    conn <- gets sqlite
    runSQL conn x

newtype Daemon a = Daemon { unDaemon :: RWST Config (Transaction IO) Session (LoggingT IO) a }
    deriving ( Applicative, Functor, Monad, MonadIO, MonadState Session
             , MonadReader Config, MonadWriter (Transaction IO), MonadThrow, MonadLogger, MonadLoggerIO )

-- newtype Entangled env a = Entangled { unEntangled :: WriterT Transaction (RIO env) a }
--     deriving ( Applicative, Functor, Monad, MonadIO, MonadReader env, MonadWriter Transaction )

-- instance MonadFileIO (Entangled env) where
instance MonadFileIO Daemon where
    readFile path       = runFileIO $ readFile path
    dump = runFileIO . dump'
    writeFile path text = do
        old_content' <- liftIO $ try $ runFileIO $ readFile path
        case (old_content' :: Either IOException Text) of
            Right old_content | old_content == text -> return ()
                              | otherwise           -> actionw
            Left  _                                 -> actionc
        where actionw   = tell $ doc (msgWrite path)
                              <> plan (runFileIO $ writeFile path text)
              actionc   = tell $ doc (msgCreate path)
                              <> plan (runFileIO $ writeFile path text)

    deleteFile path     = tell $ doc (msgDelete path)
                              <> plan (runFileIO $ deleteFile path)
```

Every time an event happens we send it to `_eventChannel`. When we tangle we change the `_daemonState` to `Tangling`. Write events to target files are then not triggering a stitch. The other way around, if the daemon is in `Stitching` state, write events to the markdown source do not trigger a tangle. Because these events will arrive asynchronously, we use an `MVar` to change the state.

Setting the state is a bit involved (a bit more than with an `IORef`), but it guarantees safe use in a multi-threaded environment. An `MVar` can only be set if it is first emptied, the combined action can be done with `modifyMVar_`.

``` {.haskell #daemon-session}
setDaemonState :: ( MonadIO m
                  , MonadState Session m )
               => DaemonState -> m ()
setDaemonState s = do
    state <- gets daemonState
    liftIO $ modifyMVar_ state (const $ return s)
```

## Watching

``` {.haskell #daemon-imports}
import Data.List (nub, (\\))
import Control.Monad (mapM)
```

The `passEvent` function acts as the call-back for the FSNotify watcher. There are two strategies in which editors save files:

    * remove and create: Vim (by default), gedit and many more editors do this. Actually, the content is written to a temporary file, which is then renamed to the existing file. These operations are atomic so that no data is lost if the system crashes.
    * modify: VS Code does this.

We have to be flexible in how we interpret the incomming events. The most important bit is that we need to ignore the `delete` events. 

`FSNotify` lets us watch directories containing the files we're interested in. In `passEvent` we need to check if the event is actually on an involved file.

``` {.haskell #daemon-watches}
passEvent :: MVar DaemonState -> Chan Event
          -> [FilePath] -> [FilePath] -> FSNotify.Event -> IO ()
passEvent _      _       _    _    FSNotify.Removed {} = return ()
passEvent state' channel srcs tgts fsEvent = do
    putStrLn $ show fsEvent
    abs_path <- canonicalizePath $ FSNotify.eventPath fsEvent
    state    <- readMVar state'

    let isSourceFile = any (equalFilePath abs_path) srcs
        isTargetFile = any (equalFilePath abs_path) tgts
        pass         = case state of
                         Idle      -> isSourceFile || isTargetFile
                         Tangling  -> isSourceFile
                         Stitching -> isTargetFile

    when pass $ do
        let etype = if isSourceFile then WriteSource else WriteTarget
        writeChan channel (etype abs_path)
```

``` {.haskell #daemon-watches}
setWatch :: Daemon ()
setWatch = do
    srcs <- db listSourceFiles >>= (liftIO . mapM canonicalizePath)
    tgts <- db listTargetFiles >>= (liftIO . mapM canonicalizePath)
    fsnotify <- gets manager
    channel  <- gets eventChannel

    let abs_dirs = nub $ map takeDirectory (srcs <> tgts)
    rel_dirs <- liftIO $ mapM makeRelativeToCurrentDirectory abs_dirs

    state <- gets daemonState
    stopActions <- liftIO $ mapM
        (\dir -> FSNotify.watchDir fsnotify dir (const True)
                                   (passEvent state channel srcs tgts))
        abs_dirs
    modify (\s -> s{ watches=stopActions })

    logInfoN $ "watching: " <> tshow rel_dirs
```

``` {.haskell #daemon-watches}
closeWatch :: Daemon ()
closeWatch = do
    stopActions <- gets watches
    liftIO $ sequence_ stopActions
    logInfoN "suspended watches"
```

## Loading

``` {.haskell #daemon-loading}
loadSourceFile :: ( MonadFileIO m, MonadLogger m
                  , MonadReader Config m
                  , MonadState Session m
                  , MonadIO m, MonadLoggerIO m )
               => FilePath -> m ()
loadSourceFile abs_path = do
    rel_path <- liftIO $ makeRelativeToCurrentDirectory abs_path
    doc'     <- readFile abs_path >>= parseMarkdown rel_path
    case doc' of
        Left err ->
            logErrorN $ "Error loading '" <> T.pack rel_path <> "': " <> tshow err
        Right doc ->
            db $ insertDocument rel_path doc
```

``` {.haskell #daemon-loading}
loadTargetFile :: ( MonadFileIO m, MonadLogger m
                  , MonadReader Config m
                  , MonadState Session m
                  , MonadIO m, MonadLoggerIO m )
               => FilePath -> m ()
loadTargetFile abs_path = do
    rel_path <- liftIO $ makeRelativeToCurrentDirectory abs_path
    refs' <- readFile abs_path >>= stitch rel_path
    case refs' of
        Left err ->
            logErrorN $ "Error loading '" <> T.pack rel_path <> "':" <> tshow err
        Right refs ->
            db $ updateTarget refs
```

## Writing

``` {.haskell #daemon-imports}
import qualified Data.Map.Lazy as LM
```

``` {.haskell #daemon-writing}
writeTargetFile :: FilePath -> Daemon ()
writeTargetFile rel_path = do
    cfg <- ask
    refs <- db $ queryReferenceMap cfg
    let codes = expandedCode (annotateComment' cfg) refs
        tangleRef tgt lang = case codes LM.!? tgt of
            Nothing        -> logErrorN $ "Reference `" <> tshow tgt <> "` not found."
            Just (Left e)  -> logErrorN $ tshow e
            Just (Right t) -> writeFile rel_path $ unlines' [headerComment lang rel_path, t]

    tgt' <- db $ queryTargetRef rel_path
    case tgt' of
        Nothing  -> logErrorN $ "Target `" <> T.pack rel_path <> "` not found."
        Just (tgt, langName) -> do
                case languageFromName cfg langName of
                    Nothing -> logErrorN $ "Unknown language id " <> langName
                    Just lang -> tangleRef tgt lang
```

``` {.haskell #daemon-writing}
writeSourceFile :: FilePath -> Daemon ()
writeSourceFile rel_path = do
    content <- db $ stitchDocument rel_path
    writeFile rel_path content
```

## Main loop

``` {.haskell #daemon-imports}
import System.IO (stdout, hFlush, hSetBuffering, BufferMode(..))
import RIO.Directory (makeRelativeToCurrentDirectory, canonicalizePath)
import RIO.FilePath (equalFilePath, takeDirectory)
import Control.Exception (IOException)
```

The `mainLoop` is fed events and handles them.

``` {.haskell #daemon-main-loop}
wait :: Daemon ()
wait = liftIO $ threadDelay 100000

mainLoop :: Event -> Daemon ()
<<main-loop-cases>>
```

After the first event we need to wait a bit, there may be more comming.

``` {.haskell #main-loop-cases}
mainLoop (WriteSource abs_path) = do
    rel_path <- liftIO $ makeRelativeToCurrentDirectory abs_path

    wait
    setDaemonState Tangling
    closeWatch

    old_tgts <- db listTargetFiles
    loadSourceFile abs_path
    new_tgts <- db listTargetFiles
    mapM_ deleteFile $ old_tgts \\ new_tgts
    mapM_ writeTargetFile new_tgts

    wait
    setWatch
    setDaemonState Idle

mainLoop (WriteTarget abs_path) = do
    rel_path <- liftIO $ makeRelativeToCurrentDirectory abs_path
    wait
    setDaemonState Stitching
    closeWatch
    loadTargetFile abs_path
    srcs <- db listSourceFiles
    mapM_ writeSourceFile srcs
    wait
    -- setDaemonState Tangling
    -- tgts <- db listTargetFiles
    -- mapM_ writeTargetFile tgts
    -- wait
    setWatch
    setDaemonState Idle

mainLoop _ = return () 
```

## Initialisation

``` {.haskell #daemon-start}
printMsg :: Doc -> Daemon ()
printMsg = liftIO . Console.putTerminal

initSession :: Daemon ()
initSession = do
    config <- ask
    abs_paths <- liftIO $ getInputFiles config
    when (null abs_paths) $ throwM $ SystemError "No input files."
    rel_paths <- liftIO $ mapM makeRelativeToCurrentDirectory abs_paths

    db createTables

    printMsg Console.banner
    tell $ doc
         $ (P.align $ P.vsep
                   $ map (Console.bullet
                         . (P.pretty ("Monitoring " :: Text) <>)
                         . Console.fileRead)
                           rel_paths)
            <> P.line

    mapM_ loadSourceFile abs_paths 
    tgts <- db listTargetFiles
    mapM_ writeTargetFile tgts
    setWatch

foldx :: (Monad m) => (e -> s -> m s) -> [e] -> s -> m ()
foldx _ [] _ = return ()
foldx f (e:es) s = f e s >>= foldx f es

runSession :: Config -> IO ()
runSession config = do
    hSetBuffering stdout LineBuffering
    fsnotify <- FSNotify.startManager
    channel <- newChan
    daemon_state <- newMVar Idle
    db_path <- getDatabasePath config
    let dbRunner conn = do
                    let session = Session [] fsnotify channel daemon_state conn
                    (x, session', action) <- runStdoutLoggingT $ runRWST (unDaemon initSession) config session
                    runTransaction action
                    events <- getChanContents channel
                    foldx (\e s -> do
                                      (_, s', a) <- runStdoutLoggingT $ runRWST (unDaemon $ mainLoop e) config s
                                      runTransaction a
                                      return s') events session'
    liftIO $ withConnection db_path dbRunner
    liftIO $ FSNotify.stopManager fsnotify
```
