-- ------ language="Haskell" file="src/FileIO.hs" project://src/FileIO.hs#2
{-# LANGUAGE NoImplicitPrelude #-}
module FileIO where

import RIO
-- ------ begin <<file-io-imports>>[0] project://lit/a4-fileio.md
import RIO.Text (Text)
import qualified RIO.Text as T

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Catch (MonadThrow, throwM)

import Errors (EntangledError(SystemError))
import Select (selectM)
import TextUtil (tshow)
-- ------ end
-- ------ begin <<file-io-imports>>[1] project://lit/a4-fileio.md
import RIO.Directory ( createDirectoryIfMissing, doesDirectoryExist
                     , listDirectory, removeFile, removeDirectory )
import RIO.FilePath  ( (</>), splitDirectories )
import RIO.List      ( scanl1 )
-- ------ end
-- ------ begin <<file-io-imports>>[2] project://lit/a4-fileio.md
import RIO.File ( writeBinaryFileDurable )
import qualified RIO.ByteString as B
import Control.Exception ( IOException )
-- ------ end
-- ------ begin <<file-io-imports>>[3] project://src/FileIO.hs#9
import RIO.FilePath         ( takeDirectory )
import RIO.Text             ( decodeUtf8With, lenientDecode )
-- ------ end

class Monad m => MonadFileIO m where
    writeFile :: FilePath -> Text -> m ()
    deleteFile :: FilePath -> m ()
    readFile :: FilePath -> m Text
    dump :: Text -> m ()

-- ------ begin <<file-io-prim>>[0] project://src/FileIO.hs#11
ensurePath :: (MonadIO m, MonadReader env m, HasLogFunc env)
           => FilePath -> m ()
ensurePath path = selectM (return ())
    [ ( not <$> doesDirectoryExist path
      , logInfo (display $ "creating directory `" <> (T.pack path) <> "`")
        >> createDirectoryIfMissing True path ) ]
-- ------ end
-- ------ begin <<file-io-prim>>[1] project://src/FileIO.hs#13
rmDirIfEmpty :: (MonadIO m, MonadThrow m, MonadReader env m, HasLogFunc env)
             => FilePath -> m ()
rmDirIfEmpty path = selectM (return ())
    [ ( not <$> doesDirectoryExist path
      , throwM $ SystemError $ "could not remove dir: `" <> (T.pack path) <> "`")
    , ( null <$> listDirectory path
      , logInfo (display $ "removing empty directory `" <> (T.pack path) <> "`")
        >> removeDirectory path ) ]

parents :: FilePath -> [FilePath]
parents = scanl1 (</>) . splitDirectories

rmPathIfEmpty :: (MonadIO m, MonadThrow m, MonadReader env m, HasLogFunc env)
              => FilePath -> m ()
rmPathIfEmpty = mapM_ rmDirIfEmpty . reverse . parents
-- ------ end
-- ------ begin <<file-io-prim>>[2] project://src/FileIO.hs#15
writeIfChanged :: (MonadIO m, MonadThrow m, MonadReader env m, HasLogFunc env)
               => FilePath -> Text -> m ()
writeIfChanged path text = do
    old_content' <- liftIO $ try $ B.readFile path
    case (old_content' :: Either IOException B.ByteString) of
        Right old_content | old_content == new_content -> return ()
                          | otherwise                  -> write
        Left  _                                        -> write
    where new_content = T.encodeUtf8 text
          write       = logInfo (display $ "writing `" <> (T.pack path) <> "`")
                      >> writeBinaryFileDurable path new_content

dump' :: (MonadIO m, MonadReader env m, HasLogFunc env)
      => Text -> m ()
dump' text = logInfo "dumping to stdio"
         >> B.hPutStr stdout (T.encodeUtf8 text)
-- ------ end
-- ------ begin <<file-io-instance>>[0] project://src/FileIO.hs#17
newtype FileIO env a = FileIO { unFileIO :: RIO env a }
    deriving (Applicative, Functor, Semigroup, Monoid, Monad, MonadIO, MonadThrow, MonadReader env)

readFile' :: ( MonadIO m, HasLogFunc env, MonadReader env m, MonadThrow m )
          => FilePath -> m Text
readFile' path = logInfo (display $ "reading `" <> (T.pack path) <> "`")
               >> B.readFile path
               >>= return . decodeUtf8With lenientDecode

runFileIO' :: ( MonadIO m, MonadReader env m, HasLogFunc env )
          => FileIO env a -> m a
runFileIO' (FileIO f) = do
    env <- ask
    runRIO env f

runFileIO :: ( MonadIO m ) => FileIO LogFunc a -> m a
runFileIO (FileIO f) = do
    logOptions <- logOptionsHandle stderr True
    liftIO $ withLogFunc logOptions (\logFunc -> runRIO logFunc f)

instance (HasLogFunc env) => MonadFileIO (FileIO env) where
    writeFile path text = ensurePath (takeDirectory path)
                        >> writeIfChanged path text

    deleteFile path     = logInfo (display $ "deleting `" <> (T.pack path) <> "`")
                        >> removeFile path
                        >> rmPathIfEmpty (takeDirectory path)

    readFile            = readFile'

    dump                = dump'
-- ------ end
-- ------ end
