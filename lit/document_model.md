# Document structure

``` {.haskell file=src/Document.hs}
module Document
    ( module Document
    , module Errors ) where

<<import-text>>
<<import-map>>
<<import-set>>
import Data.Typeable (Typeable)
import Data.List (sort)

import Control.Monad.Catch

import Config (Language)
import TextUtil (tshow)
import Errors

<<document-structure>>
```

## Structure

A document is modelled as a series of text and code blocks. A code block is delimited by two lines starting with three backtics:

~~~
 Normal text.

 ```
 print("this is a code block")
 ```
~~~

Each code block that is of relevance to Entangled has a reference attached.

~~~
 ``` {.language #<reference>}
 ```
~~~

and possibly, a filename.

~~~
 ``` {.language #<reference> file=<path>}
 ```
~~~

An identifier may be repeated, in which case the code block is concatenated to the previous instances. Each instance will have an associated integer marking the place in the sequence.

### Reference Id
We define the type `ReferenceId`.

``` {.haskell #document-structure}
newtype ReferenceName = ReferenceName
    { unReferenceName :: Text
    } deriving (Show, Eq, Ord)

data ReferenceId = ReferenceId
    { referenceName :: ReferenceName
    , referenceCount :: Int
    } deriving (Show, Eq, Ord)

showNowebReference :: ReferenceName -> Text
showNowebReference (ReferenceName x) = "<<" <> x <> ">>"
```

The type is deriving `Ord`, so that we can use it as an index for a `Map`.

### Document
Using the `ReferenceId` type we can represent a text (or `Document`) as a sequence of plain `Text` or `ReferenceId`, paired up with a map linking each `ReferenceId` with a code block.

``` {.haskell #document-structure}
data Content
    = PlainText Text
    | Reference ReferenceId
    deriving (Show, Eq)

type ReferencePair = (ReferenceId, CodeBlock)
type ReferenceMap = Map ReferenceId CodeBlock
type FileMap = Map FilePath ReferenceName

data Document = Document
    { references      :: ReferenceMap
    , documentContent :: [Content]
    , documentTargets :: FileMap
    } deriving (Show)
```

### Accessors

``` {.haskell #document-structure}
referenceNames :: ReferenceMap -> Set ReferenceName
referenceNames = S.fromList . map referenceName . M.keys

referencesByName :: ReferenceMap -> ReferenceName -> [ReferenceId]
referencesByName refs name
    = (sort . filter ((== name) . referenceName) . M.keys) refs

codeBlocksByName :: ReferenceMap -> ReferenceName -> [CodeBlock]
codeBlocksByName refs name = map (refs M.!) $ referencesByName refs name
```

### Code blocks

A code block can have all attributes that are normally associated in the context of CSS. The following markdown,

~~~
 ``` {.class #id attribute=value}
 source
 ```
~~~

can be mapped to a list of `CodeProperty`.

``` {.haskell #document-structure}
data CodeProperty
    = CodeId Text
    | CodeAttribute Text Text
    | CodeClass Text
    deriving (Eq, Show)

getAttribute :: [CodeProperty] -> Text -> Maybe Text
getAttribute [] _ = Nothing
getAttribute (CodeAttribute k v:ps) l
    | k == l    = Just v
    | otherwise = getAttribute ps l
getAttribute (_:ps) l = getAttribute ps l
```

In our case the *class* represents the code language or an abbreviation thereof.

``` {.haskell #document-structure}
data CodeBlock = CodeBlock
    { codeLanguage   :: ProgrammingLanguage
    , codeProperties :: [CodeProperty]
    , codeSource     :: Text
    } deriving (Show, Eq)
```

A `ProgrammingLanguage` is either a known language (for which we know how to generate comments) an unknown (or misspelled) class identifier, or empty.

``` {.haskell #document-structure}
data ProgrammingLanguage
    = KnownLanguage Language
    | UnknownClass Text
    | NoLanguage
    deriving (Show, Eq)
```

## Conversion

We can convert a reference back to text by looking up the reference. If the code block is emtpy this returns `Nothing`. This is due to the choice not to include the final newline in the code block.

``` {.haskell #document-conversion}
contentToText :: ReferenceMap -> Content -> Maybe Text
contentToText ref (PlainText x) = Just x
contentToText ref (Reference r) 
    | code == "" = Nothing
    | otherwise  = Just code
    where CodeBlock _ _ code = ref M.! r
```

Stitching text back together:

``` {.haskell #document-conversion}
stitchText :: Document -> Text
stitchText (Document refs c) = T.unlines $ mapMaybe (contentToText refs) c
```

