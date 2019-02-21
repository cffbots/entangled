{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Console
    ( ConsoleT
    , run
    , msg
    , Doc
    , LogLevel(..)
    , FileAction(..)
    , putTerminal
    , msgDelete
    , msgOverwrite
    , msgCreate
    , fileRead
    , group
    , banner
    , bullet
    ) where

import Control.Monad.Reader
-- import Control.Monad.State.Class
import Control.Monad.IO.Class

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.IO as T
import Data.Map (Map)
import qualified Data.Map as M
import qualified Data.Text.Prettyprint.Doc as P
import qualified System.Console.Terminal.Size as Terminal
import qualified Data.Text.Prettyprint.Doc.Render.Terminal as ANSI

-- ==== Pretty Printing document tree ==== --

data LogLevel = Error | Warning | Message deriving (Show)
data FileAction = Read | OverWrite | Delete | Create deriving (Show)

data Annotation
    = Emphasise
    | Header
    | Decoration
    | File FileAction
    | Log LogLevel
    deriving (Show)

type Doc = P.Doc Annotation

banner :: Doc
banner =  P.annotate Emphasise "enTangleD"
       <> ", version 0.2.0: https://jhidding.github.io/enTangleD/"
       <> P.line
       <> "Copyright 2018-2019, Johan Hidding, Netherlands eScience Center"
       <> P.line
       <> "Licensed under the Apache License, Version 2.0"
       <> P.line <> P.line

msg :: P.Pretty a => LogLevel -> a -> Doc
msg level = P.annotate (Log level) . P.pretty

bullet :: Doc -> Doc
bullet = (P.annotate Decoration "•" P.<+>)

group :: Doc -> Doc -> Doc
group h d = bullet (P.annotate Header h) <> P.line <> P.indent 4 d <> P.line

msgOverwrite :: FilePath -> Doc
msgOverwrite f = bullet "Overwriting"
    P.<+> (P.annotate (File OverWrite) $ P.squotes $ P.pretty f)
    <> P.line

msgCreate :: FilePath -> Doc
msgCreate f = bullet "Creating"
    P.<+> (P.annotate (File Create) $ P.squotes $ P.pretty f)
    <> P.line

msgDelete :: FilePath -> Doc
msgDelete f = bullet "Deleting"
    P.<+> (P.annotate (File Delete) $ P.squotes $ P.pretty f)
    <> P.line

fileRead :: FilePath -> Doc
fileRead f = P.annotate (File Read) $ P.squotes $ P.pretty f

toTerminal :: Doc -> P.SimpleDocStream ANSI.AnsiStyle
toTerminal d = P.reAnnotateS tr $ P.layoutPretty P.defaultLayoutOptions d
    where tr Emphasise = ANSI.bold
          tr Header = ANSI.bold <> ANSI.color ANSI.White
          tr Decoration = ANSI.color ANSI.Black
          tr (File Read) = ANSI.color ANSI.White <> ANSI.italicized
          tr (File OverWrite) = ANSI.color ANSI.Yellow <> ANSI.italicized
          tr (File Delete) = ANSI.color ANSI.Red <> ANSI.italicized
          tr (File Create) = ANSI.color ANSI.Green <> ANSI.italicized
          tr (Log Error) = ANSI.color ANSI.Red <> ANSI.bold
          tr (Log Warning) = ANSI.color ANSI.Yellow <> ANSI.bold
          tr (Log Message) = ANSI.colorDull ANSI.White

putTerminal :: Doc -> IO ()
putTerminal = T.putStr . ANSI.renderStrict . toTerminal

-- ==== Pretty Printing document to console ==== --

data Info = Info
    { consoleSize    :: Terminal.Window Int
    , consolePalette :: Map Text Text
    } deriving (Show)

newtype ConsoleT m a = ConsoleT {
    runConsole :: ReaderT Info m a
} deriving (Applicative, Functor, Monad, MonadReader Info, MonadTrans)

type ColourName = T.Text

getColour :: MonadReader Info m => ColourName -> m Text
getColour n = reader (M.findWithDefault "" n . consolePalette)

initInfoLinux :: IO Info
initInfoLinux = do
    size <- fromMaybe (Terminal.Window 24 80) <$> Terminal.size
    let palette = M.fromList
            [ ("decoration", "\ESC[38m")
            , ("reset",   "\ESC[m")
            , ("error",   "\ESC[31m")
            , ("warning", "\ESC[33m")
            , ("message", "\ESC[m")
            ]
    return $ Info size palette

run :: MonadIO m => ConsoleT m a -> m a
run x = liftIO initInfoLinux >>= runReaderT (runConsole x)

