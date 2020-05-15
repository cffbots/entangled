# Main program

The main program runs the daemon, but also provides a number of commands to inspect and manipulate the database.

``` {.haskell #main-imports}
<<import-text>>
import qualified Data.Text.IO as T.IO
import qualified Data.Map.Lazy as LM
import Data.List (sortOn)

import Control.Monad.IO.Class
import Control.Monad.Reader
import Control.Monad.Writer
import Control.Monad.Catch
import Control.Monad.Logger
import System.Directory
import System.FilePath
```

## Encoding

On linux consoles we use unicode bullet points (`•`). On Windows, those will just be asterisks (`*`). To facilitate this, we have to enable UTF-8 encoding.

``` {.haskell #main-imports}
import GHC.IO.Encoding
```

``` {.haskell #main-set-encoding}
setLocaleEncoding utf8
```

## Options

Options are parsed using `optparse-applicative`.

``` {.haskell #main-imports}
import Options.Applicative
```

All true options are left to the sub-commands. We're leaving `<<sub-commands>>` to be expanded.

``` {.haskell #main-options}
data Args = Args
    { versionFlag :: Bool
    , subCommand :: SubCommand }

data SubCommand
    = NoCommand
    <<sub-commands>>
```

The same goes for the sub-command parsers, which are collected in `<<sub-parsers>>`.

``` {.haskell #main-options}
parseNoCommand :: Parser SubCommand
parseNoCommand = pure NoCommand

parseArgs :: Parser Args
parseArgs = Args
    <$> switch (long "version" <> short 'v' <> help "Show version information.")
    <*> ( subparser ( mempty
          <<sub-parsers>>
        ) <|> parseNoCommand )
```

And the runners.

``` {.haskell #main-imports}
import Config
```

``` {.haskell #main-run}
run :: Args -> IO ()
run Args{..}
    | versionFlag       = putStrLn "enTangleD 1.0.0"
    | otherwise         = do
        config <- configStack
        case subCommand of
            NoCommand -> return ()
            <<sub-runners>>
```

This way we can add sub-commands independently in the following sections.

### Starting the daemon

``` {.haskell #main-imports}
import Daemon
```

``` {.haskell #sub-commands}
| CommandDaemon DaemonArgs
```

``` {.haskell #sub-parsers}
<>  command "daemon" (info parseDaemonArgs ( progDesc "Run the entangled daemon." )) 
```

``` {.haskell #main-options}
data DaemonArgs = DaemonArgs
    { inputFiles  :: [String]
    } deriving (Show)

parseDaemonArgs :: Parser SubCommand
parseDaemonArgs = CommandDaemon <$> DaemonArgs
    <$> many (argument str (metavar "FILES..."))
    <**> helper
```

``` {.haskell #sub-runners}
CommandDaemon a -> runSession config
```

### Printing the config

``` {.haskell #main-imports}
import qualified Dhall
```

``` {.haskell #sub-commands}
| CommandConfig
```

``` {.haskell #sub-parsers}
<> command "config" (info (pure CommandConfig <**> helper) 
                          (progDesc "Print the default configuration."))
```

``` {.haskell #sub-runners}
CommandConfig -> T.IO.putStrLn "NYI" -- T.IO.putStrLn $ Toml.encode configCodec config
```

### Inserting files to the database

``` {.haskell #sub-commands}
| CommandInsert InsertArgs
```

``` {.haskell #sub-parsers}
<> command "insert" (info parseInsertArgs ( progDesc "Insert markdown files into database." ))
```

``` {.haskell #main-options}
data FileType = SourceFile | TargetFile

data InsertArgs = InsertArgs
    { insertType :: FileType
    , insertFiles :: [FilePath] }

parseFileType :: Parser FileType
parseFileType = (flag' SourceFile $ long "source" <> short 's' <> help "insert markdown source file")
            <|> (flag' TargetFile $ long "target" <> short 't' <> help "insert target code file")

parseInsertArgs :: Parser SubCommand
parseInsertArgs = CommandInsert <$> (InsertArgs
    <$> parseFileType
    <*> many (argument str (metavar "FILES..."))
    <**> helper)
```

``` {.haskell #sub-runners}
CommandInsert (InsertArgs SourceFile fs) -> runLoggingIO $ runInsertSources config fs
CommandInsert (InsertArgs TargetFile fs) -> runLoggingIO $ runInsertTargets config fs
```

### Tangling a single reference

``` {.haskell #sub-commands}
| CommandTangle TangleArgs
```

``` {.haskell #sub-parsers}
<> command "tangle" (info (CommandTangle <$> parseTangleArgs) ( progDesc "Retrieve tangled code." ))
```

``` {.haskell #main-options}
data TangleQuery = TangleFile FilePath | TangleRef Text | TangleAll deriving (Show)

data TangleArgs = TangleArgs
    { tangleQuery :: TangleQuery
    , tangleDecorate :: Bool
    } deriving (Show)

parseTangleArgs :: Parser TangleArgs
parseTangleArgs = TangleArgs
    <$> (   (TangleFile <$> strOption ( long "file" <> short 'f'
                                      <> metavar "TARGET" <> help "file target" ))
        <|> (TangleRef  <$> strOption ( long "ref"  <> short 'r'
                                      <> metavar "TARGET" <> help "reference target" ))
        <|> (flag' TangleAll $ long "all" <> short 'a' <> help "tangle all and write to disk" ))
    <*> switch (long "decorate" <> short 'd' <> help "Decorate with stitching comments.")
    <**> helper
```

``` {.haskell #sub-runners}
CommandTangle a -> runLoggingIO $ runTangle config a
```

### Stitching a markdown source

``` {.haskell #sub-commands}
| CommandStitch StitchArgs
```

``` {.haskell #sub-parsers}
<> command "stitch" (info (CommandStitch <$> parseStitchArgs) ( progDesc "Retrieve stitched markdown." ))
```

``` {.haskell #main-options}
data StitchArgs = StitchArgs
    { stitchTarget :: FilePath
    } deriving (Show)

parseStitchArgs :: Parser StitchArgs
parseStitchArgs = StitchArgs
    <$> argument str ( metavar "TARGET" )
    <**> helper
```

``` {.haskell #sub-runners}
CommandStitch a -> runLoggingIO $ runStitch config a
```

### Listing all target files

``` {.haskell #sub-commands}
| CommandList
```

``` {.haskell #sub-parsers}
<> command "list" (info (pure CommandList <**> helper) ( progDesc "List generated code files." ))
```

``` {.haskell #sub-runners}
CommandList -> runLoggingIO $ runList config
```

## Main

``` {.haskell file=app/Main.hs}
module Main where

<<main-imports>>

import System.Exit
import Document
import Tangle (parseMarkdown, expandedCode, annotateNaked)
import TextUtil
import Comment

<<main-options>>

main :: IO ()
main = do
    <<main-set-encoding>>
    run =<< execParser args
    where args = info (parseArgs <**> helper)
            (  fullDesc
            <> progDesc "Automatically tangles and untangles 'FILES...'."
            <> header   "enTangleD -- daemonised literate programming"
            )

newtype LoggingIO a = LoggingIO { unLoggingIO :: LoggingT IO a }
    deriving ( Applicative, Functor, Monad, MonadIO, MonadLogger, MonadLoggerIO, MonadThrow )

runLoggingIO :: LoggingIO a -> IO a
runLoggingIO x = runStdoutLoggingT $ unLoggingIO x

<<main-run>>
```

## Generics

### Create the empty database

``` {.haskell #main-imports}
import Database
import Database.SQLite.Simple
```

## Tangle

``` {.haskell #main-run}
changeFile' :: (MonadIO m) => FilePath -> Text -> m ()
changeFile' filename text = do
    rel_path <- liftIO $ makeRelativeToCurrentDirectory filename
    liftIO $ createDirectoryIfMissing True (takeDirectory filename)
    oldText <- tryReadFile filename
    case oldText of
        Just ot -> if ot /= text
            then liftIO $ T.IO.writeFile filename text
            else return ()
        Nothing -> liftIO $ T.IO.writeFile filename text

runTangle :: Config -> TangleArgs -> LoggingIO ()
runTangle cfg TangleArgs{..} = do
    dbPath <- getDatabasePath cfg
    withSQL dbPath $ do 
        createTables
        refs <- queryReferenceMap cfg
        let annotate = if tangleDecorate then annotateComment' cfg else annotateNaked
            codes = expandedCode annotate refs
            tangleRef tgt = case codes LM.!? tgt of
                Nothing -> throwM $ TangleError $ "Reference `" <> tshow tgt <> "` not found."
                Just (Left e) -> throwM $ TangleError $ tshow e
                Just (Right t) -> return t
            tangleFile f = queryTargetRef f >>= \case
                Nothing -> throwM $ TangleError $ "Target `" <> T.pack f <> "` not found."
                Just (ref, langName) -> do
                    content <- tangleRef ref
                    case languageFromName cfg langName of
                        Nothing -> throwM $ TangleError $ "Language unknown " <> langName
                        Just lang -> return $ T.unlines [headerComment lang f, content]

        case tangleQuery of
            TangleRef tgt -> tangleRef (ReferenceName tgt) >>= (\x -> liftIO $ T.IO.putStr x)
            TangleFile f  -> tangleFile f >>= (\x -> liftIO $ T.IO.putStr x)
            TangleAll -> do
                fs <- listTargetFiles
                mapM_ (\f -> tangleFile f >>= changeFile' f) fs 
```

## Stitch

``` {.haskell #main-run}
runStitch :: Config -> StitchArgs -> LoggingIO ()
runStitch config StitchArgs{..} = do 
    dbPath <- getDatabasePath config
    text <- withSQL dbPath $ do 
        createTables
        stitchDocument stitchTarget
    liftIO $ T.IO.putStrLn text
```

## List

``` {.haskell #main-run}
runList :: Config -> LoggingIO ()
runList cfg = do
    dbPath <- getDatabasePath cfg
    lst <- withSQL dbPath $ do 
        createTables
        listTargetFiles
    liftIO $ T.IO.putStrLn $ unlines' $ map T.pack lst
```

## Insert

``` {.haskell #main-imports}
import Stitch (stitch)
```

``` {.haskell #main-run}
runInsertSources :: Config -> [FilePath] -> LoggingIO ()
runInsertSources cfg files = do
    dbPath <- getDatabasePath cfg
    logInfoN $ "inserting files: " <> tshow files
    withSQL dbPath $ createTables >> mapM_ readDoc files
    where readDoc f = do
            doc <- runReaderT (liftIO (T.IO.readFile f) >>= parseMarkdown f) cfg
            case doc of
                Left e -> liftIO $ T.IO.putStrLn ("warning: " <> tshow e)
                Right d -> insertDocument f d

select :: a -> [(Bool, a)] -> a
select defaultChoice []                     = defaultChoice
select defaultChoice ((True,  x) : options) = x
select defaultChoice ((False, _) : options) = select defaultChoice options

deduplicateRefs :: [ReferencePair] -> SQL [ReferencePair]
deduplicateRefs refs = dedup sorted
    where sorted = sortOn fst refs
          dedup [] = return []
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

runInsertTargets :: Config -> [FilePath] -> LoggingIO ()
runInsertTargets cfg files = do
    dbPath <- getDatabasePath cfg
    logInfoN $ "inserting files: " <> tshow files
    withSQL dbPath $ createTables >> mapM_ readTgt files
    where readTgt f = do
            refs' <- runReaderT (liftIO (T.IO.readFile f) >>= stitch f) cfg
            case refs' of
                Left err -> logErrorN $ "Error loading '" <> T.pack f <> "': " <> formatError err
                Right refs -> updateTarget =<< deduplicateRefs refs
```

