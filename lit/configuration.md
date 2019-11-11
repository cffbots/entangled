# Configuration

``` {.haskell file=src/Config.hs}
module Config where

import Logging
import Errors

import Data.Text (Text)
import qualified Data.Text as T
<<import-set>>
import qualified Toml
import Toml (TomlCodec, (.=))
import Data.Function (on)
import Data.List (find)
import Control.Applicative ((<|>))
import Control.Monad.Extra (concatMapM)
import Control.Monad.IO.Class
import Control.Monad.Catch
import System.FilePath.Glob (glob)
import System.Directory 
import System.FilePath (takeDirectory)

<<config-types>>
<<config-tomland>>
<<config-monoid>>
<<config-defaults>>
<<config-input>>
<<config-reader>>

getDatabasePath :: (MonadIO m, MonadThrow m) => Config -> m FilePath
getDatabasePath cfg = do
    dbPath <- case configEntangled cfg >>= database of
        Nothing -> throwM $ SystemError $ "database not configured"
        Just db -> return $ T.unpack db
    liftIO $ createDirectoryIfMissing True (takeDirectory dbPath)
    return dbPath

getInputFiles :: (MonadIO m) => Config -> m [FilePath]
getInputFiles cfg = liftIO $ maybe mempty
        (concatMapM (glob . T.unpack))
        (watchList =<< configEntangled cfg)
```

Configuration can be stored in `${XDG_CONFIG_HOME}/entangled/config.toml`. Also the local directory or its parents may contain a `.entangled.toml` file. These override settings in the global configuration.

There are currently no customisation options for entangled, but I keep my options open: namespaces for references, enabling future features like git support, you name it. The one component that we do need to configure is adding languages to the mix. Entangled has to know how to generate comments in every language.

``` {.toml #example-config}
[entangled]
watch-list = ["lit/*.md"]   # list of glob-patterns
database = ".entangled.sqlite" # backend database
use-namespaces = true       # soon to be implemented
enable-git = false          # tbi somewhat less soon

[[languages]]
name = "Bel"
identifiers = ["bel"]       # case insensitive
start-comment = "; -----"   # used to insert tangle tags
                            # and also to parse them back!

[[languages]]
name = "HTML"
identifiers = ["html"]
start-comment = "<!--"
close-comment = "-->"       # some languages (HTML, CSS) only
                            # support block comments
```

The Haskell definition of the `Config` data type is

``` {.haskell #config-types}
data Entangled = Entangled
    { watchList :: Maybe [Text]
    , database :: Maybe Text
    , useNamespaces :: Maybe Bool
    } deriving (Show)

data Language = Language
    { languageName :: Text
    , languageIdentifiers :: [Text]
    , languageStartComment :: Text
    , languageCloseComment :: Maybe Text
    } deriving (Show)

instance Eq Language where
    (==) = (==) `on` languageName

instance Ord Language where
    compare = compare `on` languageName

data Config = Config
    { configEntangled :: Maybe Entangled
    , configLanguages :: Set Language
    } deriving (Show)
```

Serialisation to and from TOML:

``` {.haskell #config-tomland}
entangledCodec :: TomlCodec Entangled
entangledCodec = Entangled
    <$> Toml.dioptional (Toml.arrayOf Toml._Text "watch-list") .= watchList
    <*> Toml.dioptional (Toml.text "database") .= database
    <*> Toml.dioptional (Toml.bool "use-namespaces") .= useNamespaces

languageCodec :: TomlCodec Language
languageCodec = Language
    <$> Toml.text "name" .= languageName
    <*> Toml.arrayOf Toml._Text "identifiers" .= languageIdentifiers
    <*> Toml.text "start-comment" .= languageStartComment
    <*> Toml.dioptional (Toml.text "close-comment") .= languageCloseComment

configCodec :: TomlCodec Config
configCodec = Config
    <$> Toml.dioptional (Toml.table entangledCodec "entangled") .= configEntangled
    <*> Toml.set languageCodec "languages" .= configLanguages
```

We need to be able to stack configurations, so we implement `Monoid` on `Config`. There is a generic way of doing this using `GHC.Generic`, `DeriveGeneric` language extension and `Generic.Data` module. For the moment this would be a bit overkill.

> Tip from Merijn: put the maybes in a `First`/`Last`/`Alt` instance. This will enforce `<|>` behaviour on the monoid being used.

``` {.haskell #config-monoid}
instance Semigroup Entangled where
    a <> b = Entangled (watchList a <> watchList b)
                       (database a <|> database b)
                       (useNamespaces a <|> useNamespaces b)

instance Semigroup Config where
    a <> b = Config (configEntangled a <> configEntangled b)
                    (configLanguages a <> configLanguages b)

instance Monoid Config where
    mempty = Config mempty mempty
```

You can see this will grow out of hand as the configuration becomes a bigger thing. Note that the stacking prioritises the left most element. The complete config is then:

``` {.haskell #config-monoid}
configStack :: IO Config
configStack = do
    localConfig <- readLocalConfig
    globalConfig <- readGlobalConfig
    return $ localConfig <> globalConfig <> defaultConfig
```

## Defaults

A somewhat biased list of languages: I don't know half of you half as well as I should like; and I like less than half of you half as well as you deserve.

``` {.haskell #config-defaults}
defaultLanguages :: Set Language
defaultLanguages = S.fromList
    [ Language "C++"         ["cpp", "c++"]               "//" Nothing
    , Language "C"           ["c"]                        "//" Nothing
    , Language "Rust"        ["rust"]                     "//" Nothing
    , Language "Haskell"     ["hs", "haskell"]            "--" Nothing
    , Language "Python"      ["py", "python", "python3"]  "##" Nothing
    , Language "Julia"       ["jl", "julia"]              "##" Nothing
    , Language "JavaScript"  ["js", "javascript", "ecma"] "//" Nothing
    , Language "Scheme"      ["scm", "scheme"]            ";;" Nothing
    , Language "R"           ["r"]                        "##" Nothing
    , Language "YAML"        ["yaml"]                     "##" Nothing
    , Language "Gnuplot"     ["gnuplot"]                  "##" Nothing
    , Language "Make"        ["make", "makefile"]         "##" Nothing
    , Language "Elm"         ["elm"]                      "--" Nothing
    , Language "HTML"        ["html"]                     "<!--" (Just "-->")
    , Language "CSS"         ["css"]                      "/*" (Just "*/")
    , Language "Awk"         ["awk"]                      "##" Nothing
    , Language "OCaml"       ["ocaml"]                    "(*" (Just "*)")
    , Language "LaTeX"       ["latex"]                    "%%" Nothing
    , Language "Lua"         ["lua"]                      "--" Nothing
    , Language "OpenCL"      ["opencl"]                   "//" Nothing
    , Language "SQLite"      ["sqlite"]                   "--" Nothing
    ]

defaultConfig :: Config
defaultConfig = Config
    { configEntangled = Just $
          Entangled { useNamespaces=Just False
                    , database=Just ".entangled/db.sqlite"
                    , watchList=Nothing
                    }
    , configLanguages = defaultLanguages
    }
```

### Reading config files

:::TODO
NYI
:::

``` {.haskell #config-input}
readLocalConfig :: IO Config
readLocalConfig = return mempty

readGlobalConfig :: IO Config
readGlobalConfig = return mempty
```

## Processing

``` {.haskell #config-reader}
lookupLanguage :: Config -> Text -> Maybe Language
lookupLanguage cfg x
    = find (elem x . languageIdentifiers) 
    $ configLanguages cfg

languageFromName :: Config -> Text -> Maybe Language
languageFromName cfg x
    = find ((== x) . languageName)
    $ configLanguages cfg
```

