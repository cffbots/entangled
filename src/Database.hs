-- ------ language="Haskell" file="src/Database.hs"
{-# LANGUAGE DeriveGeneric, OverloadedLabels #-}
module Database where

-- ------ begin <<database-imports>>[0]
import Logging

import Database.SQLite.Simple
import Database.SQLite.Simple.FromRow

import Control.Monad.Reader
import Control.Monad.IO.Class
import Control.Monad.Catch
import Control.Monad.Writer

-- ------ begin <<import-text>>[0]
import qualified Data.Text as T
import Data.Text (Text)
-- ------ end
-- ------ end
-- ------ begin <<database-imports>>[1]
-- ------ begin <<import-map>>[0]
import qualified Data.Map.Strict as M
import Data.Map.Strict (Map)
-- ------ end
import Data.Maybe (catMaybes)
import Data.Int (Int64)

import Document
import Config
-- ------ end
-- ------ begin <<database-types>>[0]
newtype SQL a = SQL { unSQL :: WriterT [(LogLevel, Text)] (ReaderT Connection IO) a }
    deriving (Applicative, Functor, Monad, MonadIO, MonadThrow, MonadLogger)

class (MonadIO m, MonadThrow m, MonadLogger m) => MonadSQL m where
    getConnection :: m Connection
    runSQL :: (MonadIO n, MonadLogger n) => Connection -> m a -> n a

instance MonadSQL SQL where
    getConnection = SQL ask
    runSQL conn (SQL x) = do
        (x, msgs) <- liftIO $ runReaderT (runWriterT x) conn
        forwardEntries msgs
        return x

withSQL :: (MonadIO m, MonadLogger m) => FilePath -> SQL a -> m a
withSQL p (SQL x) = do
    (x, msgs) <- liftIO $ withConnection p (liftIO . runReaderT (runWriterT x))
    forwardEntries msgs
    return x
-- ------ end
-- ------ begin <<database-types>>[1]
type RedirectLog m a = WriterT [(LogLevel, Text)] m a

redirectLogger :: (MonadIO m, MonadSQL n) => Connection -> n a -> RedirectLog m a
redirectLogger conn x = runSQL conn x

withTransactionM :: (MonadSQL m) => m a -> m a
withTransactionM t = do
    conn <- getConnection
    (x, msgs) <- liftIO $ withTransaction conn $ runWriterT $ redirectLogger conn t
    forwardEntries msgs
    return x
-- ------ end
-- ------ begin <<database-insertion>>[0]
insertCodes :: Int64 -> ReferenceMap -> SQL ()
insertCodes docId codes = do
        conn <- getConnection
        liftIO $ executeMany conn "insert into `codes` values (?,?,?,?,?)" rows
    where codeRow ( (ReferenceId (ReferenceName name) count)
                  , (CodeBlock (KnownLanguage Language{languageName}) _ source) )
              = Just (name, count, source, languageName, docId)
          codeRow _
              = Nothing
          rows = catMaybes $ map codeRow (M.toList codes)
-- ------ end
-- ------ begin <<database-insertion>>[1]
insertContent :: Int64 -> [Content] -> SQL ()
insertContent docId content = do
        conn <- getConnection
        liftIO $ executeMany conn "insert into `content`(`document`,`plain`,`codeName`,`codeOrdinal`) values (?,?,?,?)" rows
    where contentRow (PlainText text)
              = (docId, Just text, Nothing, Nothing)
          contentRow (Reference (ReferenceId (ReferenceName name) count))
              = (docId, Nothing, Just name, Just count)
          rows = map contentRow content
-- ------ end
-- ------ begin <<database-insertion>>[2]
insertTargets :: Int64 -> Map FilePath ReferenceName -> SQL ()
insertTargets docId files = do
        conn <- getConnection
        liftIO $ executeMany conn "insert into `targets` values (?, ?, ?)" rows
    where targetRow (path, ReferenceName name) = (path, name, docId)
          rows = map targetRow (M.toList files)
-- ------ end
-- ------ begin <<database-update>>[0]
getDocumentId :: FilePath -> SQL (Maybe Int64)
getDocumentId rel_path = do
    conn <- getConnection
    docId' <- liftIO $ query conn "select `id` from `documents` where `filename` is ?" (Only rel_path)
    case docId' of
        []             -> return Nothing
        [(Only docId)] -> return $ Just docId
        _              -> throwM $ DatabaseError
                                 $ "file `" <> T.pack rel_path <> "` has multiple entries."

removeDocumentData :: Int64 -> SQL ()
removeDocumentData docId = do
    conn <- getConnection
    liftIO $ do
        execute conn "delete from `content` where `document` is ?" (Only docId)
        execute conn "delete from `codes` where `document` is ?" (Only docId)
        execute conn "delete from `targets` where `document` is ?" (Only docId)

insertDocument :: FilePath -> Document -> SQL ()
insertDocument rel_path Document{..} = do
    conn <- getConnection
    docId' <- getDocumentId rel_path
    withTransactionM $ do
        docId <- case docId' of
            Just docId -> do
                logMessage $ "Replacing '" <> T.pack rel_path <> "'."
                removeDocumentData docId >> return docId
            Nothing    -> do
                logMessage $ "Inserting new '" <> T.pack rel_path <> "'."
                liftIO $ execute conn "insert into `documents`(`filename`) values (?)" (Only rel_path)
                liftIO $ lastInsertRowId conn
        insertCodes docId references
        insertContent docId documentContent
        insertTargets docId documentTargets
-- ------ end
-- ------ begin <<database-update>>[1]
updateTarget :: [ReferencePair] -> SQL () 
updateTarget refs = do
    conn <- getConnection
    let update (ReferenceId (ReferenceName name) count, CodeBlock{codeSource})
            = execute conn "update `codes` set `source` = ? where `name` is ? and `ordinal` is ?"
                  (codeSource, name, count)
    liftIO $ mapM_ update refs
-- ------ end
-- ------ begin <<database-queries>>[0]
listTargetFiles :: SQL [FilePath]
listTargetFiles = do
    conn <- getConnection
    map fromOnly <$>
        liftIO (query_ conn "select (`filename`) from `targets`" :: IO [Only FilePath])
-- ------ end
-- ------ begin <<database-queries>>[1]
listSourceFiles :: SQL [FilePath]
listSourceFiles = do
    conn <- getConnection
    map fromOnly <$>
        liftIO (query_ conn "select (`filename`) from `documents`" :: IO [Only FilePath])
-- ------ end
-- ------ begin <<database-queries>>[2]
queryReferenceMap :: ( MonadReader Config m
                     , MonadSQL m )
                  => m ReferenceMap
queryReferenceMap = do
        conn <- getConnection
        config <- ask
        rows <- liftIO (query_ conn "select (`name`, `ordinal`, `source`, `language`) from `codes`" :: IO [(Text, Int, Text, Text)])
        M.fromList <$> mapM (refpair config) rows
    where refpair config (name, ordinal, source, lang) =
            case (languageFromName config lang) of
                Nothing -> throwM $ DatabaseError $ "unknown language: " <> lang
                Just l  -> return ( ReferenceId (ReferenceName name) ordinal
                                  , CodeBlock (KnownLanguage l) [] source )
-- ------ end
-- ------ end
