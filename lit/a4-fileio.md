## FileIO

``` {.haskell file=src/FileIO.hs}
{-# LANGUAGE ScopedTypeVariables #-}
module FileIO where

import qualified Data.Text as T
import Data.Bits ((.&.))

import Std.Data.CBytes (CBytes, pack)
import Std.IO.FileSystem (stat, mkdir, rmdir, unlink, UVStat(..), UVFileMode(..))
import Std.IO.Exception (NoSuchThing(..), SomeIOException(..), Handler(..), try, catches)

import System.FilePath (splitDirectories, (</>))

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Catch (MonadThrow, throwM)

import Errors (EntangledError(SystemError))
import Select (select)

fromFilePath :: FilePath -> CBytes
fromFilePath = pack

safeStat :: (MonadIO m, MonadThrow m) => FilePath -> m (Maybe UVStat)
safeStat path = liftIO $
    (Just <$> stat (fromFilePath path)) `catches`
        [ Handler (\ (ex :: NoSuchThing) -> return Nothing)
        , Handler (\ (ex :: SomeIOException) -> throwM $
                     SystemError $ "failed `stat` on `" <> (T.pack path) <> "`") ]

exists :: (MonadIO m, MonadThrow m) => FilePath -> m Bool
exists path = maybe False (const True) <$> (safeStat path)

isDir :: (MonadIO m, MonadThrow m) => FilePath -> m Bool
isDir path = maybe False checkMode <$> (safeStat path)
    where checkMode s = (stMode s .&. 0o170000) == 0o040000

ensureDir' :: (MonadIO m, MonadThrow m) => FilePath -> m ()
ensureDir' path = do
    x <- exists path
    d <- isDir path
    select (throwM $ SystemError $ "cannot create dir: `" <> (T.pack path)
                                <> "`, exists and is a file")
           [ (d,     return ())
           , (not x, liftIO $ mkdir (fromFilePath path) mode) ]
    where mode = 0o0775

parents :: FilePath -> [FilePath]
parents = scanl1 (</>) . splitDirectories

ensureDir :: (MonadIO m, MonadThrow m) => FilePath -> m ()
ensureDir = mapM_ ensureDir' . parents
```
