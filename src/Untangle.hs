-- ------ language="Haskell" file="src/Untangle.hs"
module Untangle where

-- ------ begin <<untangle-imports>>[0]
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
-- ------ begin <<import-text>>[0]
import qualified Data.Text as T
import Data.Text (Text)
-- ------ end
import qualified Data.Map.Strict as M
import Control.Monad.Reader (MonadReader, ask, asks, ReaderT, runReaderT)
import Control.Monad (when)
import Data.Maybe (isNothing, catMaybes)
-- ------ end
-- ------ begin <<source-parser>>[0]
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
-- ------ end
-- ------ begin <<source-parser>>[1]
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
-- ------ end
-- ------ begin <<untangle>>[0]
type SourceParser = ReaderT Config (Parsec Void (ListStream Text))

untangle :: ( MonadReader Config m )
         => FilePath -> Text
         -> m (Either EntangledError [ReferencePair])
untangle filename text = do
    p <- asks $ runReaderT (sourceDocument :: SourceParser [ReferencePair])
    let refs = parse p filename $ ListStream (T.lines text)
    return $ toEntangledError UntangleError refs
-- ------ end
-- ------ end
