-- ------ language="Haskell" file="src/Database.hs" project://src/Database.hs#2
{-# LANGUAGE DeriveGeneric, OverloadedLabels, NoImplicitPrelude #-}
module Database where

import RIO
import RIO.List (initMaybe, sortOn)

-- ------ begin <<database-imports>>[0] project://src/Database.hs#3
import Paths_entangled

import Database.SQLite.Simple
import Database.SQLite.Simple.FromRow

import Control.Monad.Reader
import Control.Monad.IO.Class
import Control.Monad.Catch
-- import Control.Monad.Logger

-- ------ begin <<import-text>>[0] project://lit/01-entangled.md
import qualified Data.Text as T
import Data.Text (Text)
-- ------ end
import qualified Data.Text.IO as T.IO
-- ------ end
-- ------ begin <<database-imports>>[1] project://src/Database.hs#7
-- ------ begin <<import-map>>[0] project://lit/01-entangled.md
import qualified Data.Map.Strict as M
import Data.Map.Strict (Map)
-- ------ end
import Data.Maybe (catMaybes)
import Data.Int (Int64)

import Document
import Config
import Select (select)
import TextUtil (unlines')
-- ------ end
-- ------ begin <<database-types>>[0] project://src/Database.hs#11
class HasConnection env where
    connection :: Lens' env Connection

data SQLEnv = SQLEnv
    { sqlLogFunc    :: LogFunc
    , sqlConnection :: Connection }

newtype SQL a = SQL { unSQL :: RIO SQLEnv a }  -- ReaderT Connection (LoggingT IO) a }
    deriving (Applicative, Functor, Monad, MonadIO, MonadThrow, MonadReader SQLEnv)

instance HasLogFunc SQLEnv where
    logFuncL = lens sqlLogFunc (\x y -> x { sqlLogFunc = y })

instance HasConnection SQLEnv where
    connection = lens sqlConnection (\x y -> x { sqlConnection = y })

getConnection :: (HasConnection env, MonadReader env m) => m Connection
getConnection = view connection

db :: (MonadIO m, MonadReader env m, HasConnection env, HasLogFunc env)
   => SQL a -> m a
db (SQL x) = do
    logFunc <- view logFuncL
    conn    <- view connection
    runRIO (SQLEnv logFunc conn) x

runSQL :: (MonadIO m) => Connection -> SQL a -> m a
runSQL conn (SQL x) = do
    logOptions <- logOptionsHandle stderr True
    liftIO $ withLogFunc logOptions (\logFunc ->
        runRIO (SQLEnv logFunc conn) x)

runSQL' :: (MonadIO m) => SQLEnv -> SQL a -> m a
runSQL' env (SQL x) = runRIO env x

withSQL :: (MonadIO m) => FilePath -> SQL a -> m a
withSQL p (SQL x) = do
    logOptions <- logOptionsHandle stderr True
    liftIO $ withLogFunc logOptions (\logFunc ->
        liftIO $ withConnection p (\conn ->
            liftIO $ runRIO (SQLEnv logFunc conn) x))

expectUnique :: (MonadThrow m, Show a) => [a] -> m (Maybe a)
expectUnique []  = return Nothing
expectUnique [x] = return $ Just x
expectUnique lst = throwM $ DatabaseError $ "duplicate entry: " <> tshow lst

expectUnique' :: (MonadThrow m, Show a) => (a -> b) -> [a] -> m (Maybe b)
expectUnique' _ []  = return Nothing
expectUnique' f [x] = return $ Just (f x)
expectUnique' _ lst = throwM $ DatabaseError $ "duplicate entry: " <> tshow lst
-- ------ end
-- ------ begin <<database-types>>[1] project://src/Database.hs#13
withTransactionM :: SQL a -> SQL a
withTransactionM t = do
    env <- ask
    conn <- getConnection
    liftIO $ withTransaction conn (runSQL' env t)
-- ------ end
-- ------ begin <<database-create>>[0] project://src/Database.hs#15
schema :: IO [Query]
schema = do
    schema_path <- getDataFileName "data/schema.sql"
    qs <- initMaybe <$> T.splitOn ";" <$> T.IO.readFile schema_path
    return $ maybe [] (map Query) qs

createTables :: (MonadIO m, MonadReader env m, HasConnection env) => m ()
createTables = do
    conn <- getConnection
    liftIO $ schema >>= mapM_ (execute_ conn)
-- ------ end
-- ------ begin <<database-insertion>>[0] project://lit/03-database.md
insertCode :: Int64 -> ReferencePair -> SQL ()
insertCode docId ( ReferenceId _ (ReferenceName name) count
                 , CodeBlock (KnownLanguage langName) attrs source ) = do
    conn <- getConnection
    liftIO $ do
        execute conn "insert into `codes`(`name`,`ordinal`,`source`,`language`,`document`) \
                     \ values (?,?,?,?,?)" (name, count, source, langName, docId)
        codeId <- lastInsertRowId conn
        executeMany conn "insert into `classes` values (?,?)"
                    [(className, codeId) | className <- getClasses attrs]
    where getClasses [] = []
          getClasses (CodeClass c : cs) = c : getClasses cs
          getClasses (_ : cs) = getClasses cs

insertCodes :: Int64 -> ReferenceMap -> SQL ()
insertCodes docId codes = mapM_ (insertCode docId) (M.toList codes)
-- ------ end
-- ------ begin <<database-insertion>>[1] project://lit/03-database.md
queryCodeId' :: Int64 -> ReferenceId -> SQL (Maybe Int64)
queryCodeId' docId (ReferenceId _ (ReferenceName name) count) = do
    conn <- getConnection
    expectUnique' fromOnly =<< (liftIO $ query conn codeQuery (docId, name, count))
    where codeQuery = "select `id` from `codes` where \
                      \ `document` is ? and `name` is ? and `ordinal` is ?"

queryCodeId :: ReferenceId -> SQL (Maybe Int64)
queryCodeId (ReferenceId doc (ReferenceName name) count) = do
    conn    <- getConnection
    expectUnique' fromOnly =<< (liftIO $ query conn codeQuery (doc, name, count))
    where codeQuery = "select `codes`.`id` \
                      \ from `codes` inner join `documents` \
                      \     on `documents`.`id` is `codes`.`document` \
                      \ where   `documents`.`filename` is ? \
                      \     and `name` is ? \
                      \     and `ordinal` is ?"

queryCodeSource :: ReferenceId -> SQL (Maybe Text)
queryCodeSource (ReferenceId doc (ReferenceName name) count) = do
    conn    <- getConnection
    expectUnique' fromOnly =<< (liftIO $ query conn codeQuery (doc, name, count))
    where codeQuery = "select `codes`.`source` \
                      \ from `codes` inner join `documents` \
                      \     on `documents`.`id` is `codes`.`document` \
                      \ where   `documents`.`filename` is ? \
                      \     and `name` is ? \
                      \     and `ordinal` is ?"

contentToRow :: Int64 -> Content -> SQL (Int64, Maybe Text, Maybe Int64)
contentToRow docId (PlainText text) = return (docId, Just text, Nothing)
contentToRow docId (Reference ref)  = do
    codeId' <- queryCodeId' docId ref
    case codeId' of
        Nothing     -> throwM $ DatabaseError $ "expected reference: " <> tshow ref
        Just codeId -> return (docId, Nothing, Just codeId)

insertContent :: Int64 -> [Content] -> SQL ()
insertContent docId content = do
    rows <- mapM (contentToRow docId) content
    conn <- getConnection
    liftIO $ executeMany conn "insert into `content`(`document`,`plain`,`code`) values (?,?,?)" rows
-- ------ end
-- ------ begin <<database-insertion>>[2] project://src/Database.hs#21
insertTargets :: Int64 -> FileMap -> SQL ()
insertTargets docId files = do
        conn <- getConnection
        -- liftIO $ print rows
        liftIO $ executeMany conn "replace into `targets`(`filename`,`codename`,`language`,`document`) values (?, ?, ?, ?)" rows
    where targetRow (path, (ReferenceName name, lang)) = (path, name, lang, docId)
          rows = map targetRow (M.toList files)
-- ------ end
-- ------ begin <<database-update>>[0] project://src/Database.hs#23
getDocumentId :: FilePath -> SQL (Maybe Int64)
getDocumentId rel_path = do
        conn <- getConnection
        expectUnique' fromOnly =<< (liftIO $ query conn documentQuery (Only rel_path))
    where documentQuery = "select `id` from `documents` where `filename` is ?"

orphanTargets :: Int64 -> SQL ()
orphanTargets docId = do
    conn <- getConnection
    liftIO $ execute conn "update `targets` set `document` = null where `document` is ?" (Only docId)

clearOrphanTargets :: SQL ()
clearOrphanTargets = do
    conn <- getConnection
    liftIO $ execute_ conn "delete from `targets` where `document` is null"

removeDocumentData :: Int64 -> SQL ()
removeDocumentData docId = do
    orphanTargets docId
    conn <- getConnection
    liftIO $ do
        execute conn "delete from `content` where `document` is ?" (Only docId)
        execute conn "delete from `codes` where `document` is ?" (Only docId)

insertDocument :: FilePath -> Document -> SQL ()
insertDocument rel_path Document{..} = do
    conn <- getConnection
    docId' <- getDocumentId rel_path
    docId <- case docId' of
        Just docId -> do
            logInfo $ display $ "Replacing '" <> T.pack rel_path <> "'."
            removeDocumentData docId >> return docId
        Nothing    -> do
            logInfo $ display $ "Inserting new '" <> T.pack rel_path <> "'."
            liftIO $ execute conn "insert into `documents`(`filename`) values (?)" (Only rel_path)
            liftIO $ lastInsertRowId conn
    insertCodes docId references
    insertContent docId documentContent
    insertTargets docId documentTargets
-- ------ end
-- ------ begin <<database-update>>[1] project://lit/03-database.md
fromMaybeM :: Monad m => m a -> m (Maybe a) -> m a
fromMaybeM whenNothing x = do
    unboxed <- x
    case unboxed of
        Nothing -> whenNothing
        Just x' -> return x'

updateCode :: ReferencePair -> SQL ()
updateCode (ref, CodeBlock {codeSource}) = do
    codeId <- fromMaybeM (throwM $ DatabaseError $ "could not find code '" <> tshow ref <> "'")
                         (queryCodeId ref)
    conn   <- getConnection
    liftIO $ execute conn "update `codes` set `source` = ? where `id` is ?" (codeSource, codeId)

updateTarget :: [ReferencePair] -> SQL ()
updateTarget refs = withTransactionM $ mapM_ updateCode refs
-- ------ end
-- ------ begin <<database-queries>>[0] project://src/Database.hs#27
listOrphanTargets :: SQL [FilePath]
listOrphanTargets = do
    conn <- getConnection
    map fromOnly <$>
        liftIO (query_ conn "select `filename` from `targets` where `document` is null" :: IO [Only FilePath])

listTargetFiles :: SQL [FilePath]
listTargetFiles = do
    conn <- getConnection
    map fromOnly <$>
        liftIO (query_ conn "select `filename` from `targets` where `document` is not null" :: IO [Only FilePath])
-- ------ end
-- ------ begin <<database-queries>>[1] project://lit/03-database.md
listSourceFiles :: SQL [FilePath]
listSourceFiles = do
    conn <- getConnection
    map fromOnly <$>
        liftIO (query_ conn "select `filename` from `documents`" :: IO [Only FilePath])
-- ------ end
-- ------ begin <<database-queries>>[2] project://lit/03-database.md
queryTargetRef :: FilePath -> SQL (Maybe (ReferenceName, Text))
queryTargetRef rel_path = do
    conn <- getConnection
    val  <- expectUnique =<< (liftIO $ query conn targetQuery (Only rel_path))
    return $ case val of
        Nothing           -> Nothing
        Just (name, lang) -> Just (ReferenceName name, lang)
    where targetQuery = "select `codename`,`language` from `targets` where `filename` is ?"
-- ------ end
-- ------ begin <<database-queries>>[3] project://lit/03-database.md
stitchDocument :: FilePath -> SQL Text
stitchDocument rel_path = do
    conn <- getConnection
    docId <- getDocumentId rel_path >>= \case
        Nothing -> throwM $ StitchError $ "File `" <> T.pack rel_path <> "` not in database."
        Just x  -> return x
    result <- liftIO (query conn "select coalesce(`plain`,`codes`.`source`) from `content` \
                                 \  left outer join `codes` \
                                 \    on `code` is `codes`.`id` \
                                 \  where `content`.`document` is ?" (Only docId) :: IO [Only Text])
    return $ unlines' $ map fromOnly result
-- ------ end
-- ------ begin <<database-queries>>[4] project://lit/03-database.md
queryReferenceMap :: Config -> SQL ReferenceMap
queryReferenceMap config = do
        conn <- getConnection
        rows <- liftIO (query_ conn "select `documents`.`filename`, `name`, `ordinal`, `source`, `language` from `codes` inner join `documents` on `codes`.`document` is `documents`.`id`" :: IO [(FilePath, Text, Int, Text, Text)])
        M.fromList <$> mapM (refpair config) rows
    where refpair config (rel_path, name, ordinal, source, lang) =
            case (languageFromName config lang) of
                Nothing -> throwM $ DatabaseError $ "unknown language: " <> lang
                Just l  -> return ( ReferenceId rel_path (ReferenceName name) ordinal
                                  , CodeBlock (KnownLanguage lang) [] source )
-- ------ end

deduplicateRefs :: [ReferencePair] -> SQL [ReferencePair]
deduplicateRefs refs = dedup $ sortOn fst refs
    where dedup [] = return []
          dedup [x1] = return [x1]
          dedup ((ref1, code1@CodeBlock{codeSource=s1}) : (ref2, code2@CodeBlock{codeSource=s2}) : xs)
                | ref1 /= ref2 = ((ref1, code1) :) <$> dedup ((ref2, code2) : xs)
                | s1 == s2     = dedup ((ref1, code1) : xs)
                | otherwise    = do
                    old_code <- queryCodeSource ref1
                    case old_code of
                        Nothing -> throwM $ StitchError $ "ambiguous update: " <> tshow ref1 <> " not in database."
                        Just c  -> select (throwM $ StitchError $ "ambiguous update to " <> tshow ref1)
                                    [(s1 == c && s2 /= c, dedup ((ref2, code2) : xs))
                                    ,(s1 /= c && s2 == c, dedup ((ref1, code1) : xs))]
-- ------ end
