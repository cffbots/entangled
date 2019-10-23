# Untangling

```{.haskell file=src/Untangle.hs}
module Untangle where

<<untangle-imports>>
<<source-parser>>
<<untangle>>
```

Untangling starts with reading the top line to identify the file and language. Following that should be one series of referenced code block items.

The result is a list of `ReferencePair` giving all the content of the code blocks as it is given in the source file. We don't yet make it a `ReferenceMap`, since there may be duplicate conflicting entries. In this case we want to get the entry that is different from the one that we already know of.

``` {.haskell #source-parser}
sourceDocument :: ( MonadParsec e (ListStream Text) m
                  , MonadReader Config m )
               => m [ReferencePair]
sourceDocument = do
    config <- ask
    (prop, _) <- tokenP topHeader
    lang <- maybe (fail "No valid language found in header.") return
                  $ getAttribute prop "language" >>= languageFromName config
    (_, refs) <- mconcat <$> many (sourceBlock lang)
    return refs
```

A `sourceBlock` starts with a *begin* marker, then has many lines of plain source or nested `sourceBlock`s. Both `sourceBlock` and `sourceLine` return pairs of texts and references. The content of these pairs are concatenated. If a `sourceBlock` is the first in a series (index 0), the noweb reference is generated with the correct indentation.

``` {.haskell #source-parser}
sourceBlock :: ( MonadParsec e (ListStream Text) m )
            => Language -> m ([Text], [ReferencePair])
sourceBlock lang = do
    ((ref, beginIndent), _) <- tokenP (commented lang beginBlock)
    (lines, refpairs) <- mconcat <$> manyTill 
                (sourceBlock lang <|> sourceLine)
                (tokenP (commented lang endBlock))
    let unindentedLines = map (unindent beginIndent) lines
    when (any isNothing unindentedLines) $ fail "Indentation error"
    let content = unlines' $ catMaybes unindentedLines
    return ( if referenceCount ref == 0
                 then [(indent beginIndent $ nowebReference $ referenceName ref)]
                 else []
           , (ref, CodeBlock (KnownLanguage lang) [] content):refpairs )

sourceLine :: ( MonadParsec e (ListStream Text) m )
           => m ([Text], [ReferencePair])
sourceLine = do
    x <- anySingle
    return ([x], [])
```

## The `untangle` function

In the `untangle` function we take out the `Config` from the anonymous `MonadReader` and put it in a `SourceParser` monad. This transformation is the `asks . runReaderT` combo. It seems silly that we can't "inherit" the outer monad here. I tried turning the transformers around like: `ParsecT Void (ListStream Text) m`, but type deduction fails on that one.

``` {.haskell #untangle}
type SourceParser = ReaderT Config (Parsec Void (ListStream Text))

untangle :: ( MonadReader Config m )
         => FilePath -> Text
         -> m (Either EntangledError [ReferencePair])
untangle filename text = do
    p <- asks $ runReaderT (sourceDocument :: SourceParser [ReferencePair])
    let refs = parse p filename $ ListStream (T.lines text)
    return $ toEntangledError UntangleError refs
```

## Imports

``` {.haskell #untangle-imports}
import ListStream (ListStream(..), tokenP)
import Document
    ( CodeBlock(..), ProgrammingLanguage(..)
    , ReferenceId(..), ReferencePair, ReferenceMap
    , getAttribute, nowebReference
    , EntangledError(..), toEntangledError )
import Config (Config, languageFromName, Language)
import Comment (topHeader, beginBlock, endBlock, commented)
import TextUtil (indent, unindent, unlines')

import Text.Megaparsec
    ( MonadParsec, Parsec, parse, anySingle, manyTill, (<|>)
    , many )
import Data.Void (Void)
<<import-text>>
import qualified Data.Map.Strict as M
import Control.Monad.Reader (MonadReader, ask, asks, ReaderT, runReaderT)
import Control.Monad (when)
import Data.Maybe (isNothing, catMaybes)
```

