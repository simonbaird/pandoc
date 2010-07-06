{-
Copyright (C) 2006-2010 John MacFarlane <jgm@berkeley.edu>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- |
   Module      : Text.Pandoc.Parsing
   Copyright   : Copyright (C) 2006-2010 John MacFarlane
   License     : GNU GPL, version 2 or above 

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : portable

A utility library with parsers used in pandoc readers.
-}
module Text.Pandoc.Parsing ( (>>~),
                             anyLine,
                             many1Till,
                             notFollowedBy',
                             oneOfStrings,
                             spaceChar,
                             skipSpaces,
                             blankline,
                             blanklines,
                             enclosed,
                             stringAnyCase,
                             parseFromString,
                             lineClump,
                             charsInBalanced,
                             charsInBalanced',
                             romanNumeral,
                             emailAddress,
                             uri,
                             withHorizDisplacement,
                             nullBlock,
                             failIfStrict,
                             failUnlessLHS,
                             escaped,
                             anyOrderedListMarker,
                             orderedListMarker,
                             charRef,
                             gridTableHeader,
                             gridTableRow,
                             gridTableSep,
                             gridTableFooter,
                             readWith,
                             testStringWith,
                             ParserState (..),
                             defaultParserState,
                             HeaderType (..),
                             ParserContext (..),
                             QuoteContext (..),
                             NoteTable,
                             KeyTable,
                             Key (..),
                             lookupKeySrc,
                             refsMatch )
where

import Text.Pandoc.Definition
import qualified Text.Pandoc.UTF8 as UTF8 (putStrLn)
import Text.ParserCombinators.Parsec
import Text.Pandoc.CharacterReferences ( characterReference )
import Data.Char ( toLower, toUpper, ord, isAscii )
import Data.List ( intercalate, transpose )
import Network.URI ( parseURI, URI (..), isAllowedInURI )
import Control.Monad ( join, liftM )
import Text.Pandoc.Shared
import qualified Data.Map as M

-- | Like >>, but returns the operation on the left.
-- (Suggested by Tillmann Rendel on Haskell-cafe list.)
(>>~) :: (Monad m) => m a -> m b -> m a
a >>~ b = a >>= \x -> b >> return x

-- | Parse any line of text
anyLine :: GenParser Char st [Char]
anyLine = manyTill anyChar newline

-- | Like @manyTill@, but reads at least one item.
many1Till :: GenParser tok st a
          -> GenParser tok st end
          -> GenParser tok st [a]
many1Till p end = do
         first <- p
         rest <- manyTill p end
         return (first:rest)

-- | A more general form of @notFollowedBy@.  This one allows any 
-- type of parser to be specified, and succeeds only if that parser fails.
-- It does not consume any input.
notFollowedBy' :: Show b => GenParser a st b -> GenParser a st ()
notFollowedBy' p  = try $ join $  do  a <- try p
                                      return (unexpected (show a))
                                  <|>
                                  return (return ())
-- (This version due to Andrew Pimlott on the Haskell mailing list.)

-- | Parses one of a list of strings (tried in order).  
oneOfStrings :: [String] -> GenParser Char st String
oneOfStrings listOfStrings = choice $ map (try . string) listOfStrings

-- | Parses a space or tab.
spaceChar :: CharParser st Char
spaceChar = char ' ' <|> char '\t'

-- | Skips zero or more spaces or tabs.
skipSpaces :: GenParser Char st ()
skipSpaces = skipMany spaceChar

-- | Skips zero or more spaces or tabs, then reads a newline.
blankline :: GenParser Char st Char
blankline = try $ skipSpaces >> newline

-- | Parses one or more blank lines and returns a string of newlines.
blanklines :: GenParser Char st [Char]
blanklines = many1 blankline

-- | Parses material enclosed between start and end parsers.
enclosed :: GenParser Char st t   -- ^ start parser
         -> GenParser Char st end  -- ^ end parser
         -> GenParser Char st a    -- ^ content parser (to be used repeatedly)
         -> GenParser Char st [a]
enclosed start end parser = try $ 
  start >> notFollowedBy space >> many1Till parser end

-- | Parse string, case insensitive.
stringAnyCase :: [Char] -> CharParser st String
stringAnyCase [] = string ""
stringAnyCase (x:xs) = do
  firstChar <- char (toUpper x) <|> char (toLower x)
  rest <- stringAnyCase xs
  return (firstChar:rest)

-- | Parse contents of 'str' using 'parser' and return result.
parseFromString :: GenParser tok st a -> [tok] -> GenParser tok st a
parseFromString parser str = do
  oldPos <- getPosition
  oldInput <- getInput
  setInput str
  result <- parser
  setInput oldInput
  setPosition oldPos
  return result

-- | Parse raw line block up to and including blank lines.
lineClump :: GenParser Char st String
lineClump = blanklines 
          <|> (many1 (notFollowedBy blankline >> anyLine) >>= return . unlines)

-- | Parse a string of characters between an open character
-- and a close character, including text between balanced
-- pairs of open and close, which must be different. For example,
-- @charsInBalanced '(' ')'@ will parse "(hello (there))"
-- and return "hello (there)".  Stop if a blank line is
-- encountered.
charsInBalanced :: Char -> Char -> GenParser Char st String
charsInBalanced open close = try $ do
  char open
  raw <- many $     (many1 (noneOf [open, close, '\n']))
                <|> (do res <- charsInBalanced open close
                        return $ [open] ++ res ++ [close])
                <|> try (string "\n" >>~ notFollowedBy' blanklines)
  char close
  return $ concat raw

-- | Like @charsInBalanced@, but allow blank lines in the content.
charsInBalanced' :: Char -> Char -> GenParser Char st String
charsInBalanced' open close = try $ do
  char open
  raw <- many $       (many1 (noneOf [open, close]))
                  <|> (do res <- charsInBalanced' open close
                          return $ [open] ++ res ++ [close])
  char close
  return $ concat raw

-- Auxiliary functions for romanNumeral:

lowercaseRomanDigits :: [Char]
lowercaseRomanDigits = ['i','v','x','l','c','d','m']

uppercaseRomanDigits :: [Char]
uppercaseRomanDigits = map toUpper lowercaseRomanDigits

-- | Parses a roman numeral (uppercase or lowercase), returns number.
romanNumeral :: Bool                  -- ^ Uppercase if true
             -> GenParser Char st Int
romanNumeral upperCase = do
    let romanDigits = if upperCase 
                         then uppercaseRomanDigits 
                         else lowercaseRomanDigits
    lookAhead $ oneOf romanDigits 
    let [one, five, ten, fifty, hundred, fivehundred, thousand] = 
          map char romanDigits
    thousands <- many thousand >>= (return . (1000 *) . length)
    ninehundreds <- option 0 $ try $ hundred >> thousand >> return 900
    fivehundreds <- many fivehundred >>= (return . (500 *) . length)
    fourhundreds <- option 0 $ try $ hundred >> fivehundred >> return 400
    hundreds <- many hundred >>= (return . (100 *) . length)
    nineties <- option 0 $ try $ ten >> hundred >> return 90
    fifties <- many fifty >>= (return . (50 *) . length)
    forties <- option 0 $ try $ ten >> fifty >> return 40
    tens <- many ten >>= (return . (10 *) . length)
    nines <- option 0 $ try $ one >> ten >> return 9
    fives <- many five >>= (return . (5 *) . length)
    fours <- option 0 $ try $ one >> five >> return 4
    ones <- many one >>= (return . length)
    let total = thousands + ninehundreds + fivehundreds + fourhundreds +
                hundreds + nineties + fifties + forties + tens + nines +
                fives + fours + ones
    if total == 0
       then fail "not a roman numeral"
       else return total

-- Parsers for email addresses and URIs

emailChar :: GenParser Char st Char
emailChar = alphaNum <|> oneOf "-+_."

domainChar :: GenParser Char st Char
domainChar = alphaNum <|> char '-'

domain :: GenParser Char st [Char]
domain = do
  first <- many1 domainChar
  dom <- many1 $ try (char '.' >> many1 domainChar )
  return $ intercalate "." (first:dom)

-- | Parses an email address; returns original and corresponding
-- escaped mailto: URI.
emailAddress :: GenParser Char st (String, String)
emailAddress = try $ do
  firstLetter <- alphaNum
  restAddr <- many emailChar
  let addr = firstLetter:restAddr
  char '@'
  dom <- domain
  let full = addr ++ '@':dom
  return (full, escapeURI $ "mailto:" ++ full)

-- | Parses a URI. Returns pair of original and URI-escaped version.
uri :: GenParser Char st (String, String)
uri = try $ do
  let protocols = [ "http:", "https:", "ftp:", "file:", "mailto:",
                    "news:", "telnet:" ]
  lookAhead $ oneOfStrings protocols
  -- scan non-ascii characters and ascii characters allowed in a URI
  str <- many1 $ satisfy (\c -> not (isAscii c) || isAllowedInURI c)
  -- now see if they amount to an absolute URI
  case parseURI (escapeURI str) of
       Just uri' -> if uriScheme uri' `elem` protocols
                       then return (str, show uri')
                       else fail "not a URI"
       Nothing   -> fail "not a URI"

-- | Applies a parser, returns tuple of its results and its horizontal
-- displacement (the difference between the source column at the end
-- and the source column at the beginning). Vertical displacement
-- (source row) is ignored.
withHorizDisplacement :: GenParser Char st a  -- ^ Parser to apply
                      -> GenParser Char st (a, Int) -- ^ (result, displacement)
withHorizDisplacement parser = do
  pos1 <- getPosition
  result <- parser
  pos2 <- getPosition
  return (result, sourceColumn pos2 - sourceColumn pos1)

-- | Parses a character and returns 'Null' (so that the parser can move on
-- if it gets stuck).
nullBlock :: GenParser Char st Block
nullBlock = anyChar >> return Null

-- | Fail if reader is in strict markdown syntax mode.
failIfStrict :: GenParser Char ParserState ()
failIfStrict = do
  state <- getState
  if stateStrict state then fail "strict mode" else return ()

-- | Fail unless we're in literate haskell mode.
failUnlessLHS :: GenParser tok ParserState ()
failUnlessLHS = do
  state <- getState
  if stateLiterateHaskell state then return () else fail "Literate haskell feature"

-- | Parses backslash, then applies character parser.
escaped :: GenParser Char st Char  -- ^ Parser for character to escape
        -> GenParser Char st Inline
escaped parser = try $ do
  char '\\'
  result <- parser
  return (Str [result])

-- | Parses an uppercase roman numeral and returns (UpperRoman, number).
upperRoman :: GenParser Char st (ListNumberStyle, Int)
upperRoman = do
  num <- romanNumeral True
  return (UpperRoman, num)

-- | Parses a lowercase roman numeral and returns (LowerRoman, number).
lowerRoman :: GenParser Char st (ListNumberStyle, Int)
lowerRoman = do
  num <- romanNumeral False
  return (LowerRoman, num)

-- | Parses a decimal numeral and returns (Decimal, number).
decimal :: GenParser Char st (ListNumberStyle, Int)
decimal = do
  num <- many1 digit
  return (Decimal, read num)

-- | Parses a '#' returns (DefaultStyle, 1).
defaultNum :: GenParser Char st (ListNumberStyle, Int)
defaultNum = do
  char '#'
  return (DefaultStyle, 1)

-- | Parses a lowercase letter and returns (LowerAlpha, number).
lowerAlpha :: GenParser Char st (ListNumberStyle, Int)
lowerAlpha = do
  ch <- oneOf ['a'..'z']
  return (LowerAlpha, ord ch - ord 'a' + 1)

-- | Parses an uppercase letter and returns (UpperAlpha, number).
upperAlpha :: GenParser Char st (ListNumberStyle, Int)
upperAlpha = do
  ch <- oneOf ['A'..'Z']
  return (UpperAlpha, ord ch - ord 'A' + 1)

-- | Parses a roman numeral i or I
romanOne :: GenParser Char st (ListNumberStyle, Int)
romanOne = (char 'i' >> return (LowerRoman, 1)) <|>
           (char 'I' >> return (UpperRoman, 1))

-- | Parses an ordered list marker and returns list attributes.
anyOrderedListMarker :: GenParser Char st ListAttributes 
anyOrderedListMarker = choice $ 
  [delimParser numParser | delimParser <- [inPeriod, inOneParen, inTwoParens],
                           numParser <- [decimal, defaultNum, romanOne,
                           lowerAlpha, lowerRoman, upperAlpha, upperRoman]]

-- | Parses a list number (num) followed by a period, returns list attributes.
inPeriod :: GenParser Char st (ListNumberStyle, Int)
         -> GenParser Char st ListAttributes 
inPeriod num = try $ do
  (style, start) <- num
  char '.'
  let delim = if style == DefaultStyle
                 then DefaultDelim
                 else Period
  return (start, style, delim)
 
-- | Parses a list number (num) followed by a paren, returns list attributes.
inOneParen :: GenParser Char st (ListNumberStyle, Int)
           -> GenParser Char st ListAttributes 
inOneParen num = try $ do
  (style, start) <- num
  char ')'
  return (start, style, OneParen)

-- | Parses a list number (num) enclosed in parens, returns list attributes.
inTwoParens :: GenParser Char st (ListNumberStyle, Int)
            -> GenParser Char st ListAttributes 
inTwoParens num = try $ do
  char '('
  (style, start) <- num
  char ')'
  return (start, style, TwoParens)

-- | Parses an ordered list marker with a given style and delimiter,
-- returns number.
orderedListMarker :: ListNumberStyle 
                  -> ListNumberDelim 
                  -> GenParser Char st Int
orderedListMarker style delim = do
  let num = defaultNum <|>  -- # can continue any kind of list
            case style of
               DefaultStyle -> decimal
               Decimal      -> decimal
               UpperRoman   -> upperRoman
               LowerRoman   -> lowerRoman
               UpperAlpha   -> upperAlpha
               LowerAlpha   -> lowerAlpha
  let context = case delim of
               DefaultDelim -> inPeriod
               Period       -> inPeriod
               OneParen     -> inOneParen
               TwoParens    -> inTwoParens
  (start, _, _) <- context num
  return start

-- | Parses a character reference and returns a Str element.
charRef :: GenParser Char st Inline
charRef = do
  c <- characterReference
  return $ Str [c]

-- grid tables, common to RST and Markdown:

gridTableSplitLine :: [Int] -> String -> [String]
gridTableSplitLine indices line =
  map removeFinalBar $ tail $ splitByIndices (init indices) line

gridPart :: Char -> GenParser Char st (Int, Int)
gridPart ch = do
  dashes <- many1 (char ch)
  char '+'
  return (length dashes, length dashes + 1)

gridDashedLines :: Char -> GenParser Char st [(Int,Int)]
gridDashedLines ch = try $ char '+' >> many1 (gridPart ch) >>~ blankline

removeFinalBar :: String -> String
removeFinalBar = reverse . dropWhile (=='|') .  dropWhile (`elem` " \t") .
                 reverse

-- | Separator between rows of grid table.
gridTableSep :: Char -> GenParser Char ParserState Char
gridTableSep ch = try $ gridDashedLines ch >> return '\n'

-- | Parse header for a grid table.
gridTableHeader :: Bool -- ^ Headerless table
                -> GenParser Char ParserState ([String], [Alignment], [Int])
gridTableHeader headless = try $ do
  optional blanklines
  dashes <- gridDashedLines '-'
  rawContent  <- if headless
                    then return $ repeat "" 
                    else many1
                         (notFollowedBy (gridTableSep '=') >> char '|' >>
                           many1Till anyChar newline)
  if headless
     then return ()
     else gridTableSep '=' >> return ()
  let lines'   = map snd dashes
  let indices  = scanl (+) 0 lines'
  let aligns   = replicate (length lines') AlignDefault
  -- RST does not have a notion of alignments
  let rawHeads = if headless
                    then replicate (length dashes) ""
                    else map (intercalate " ") $ transpose
                       $ map (gridTableSplitLine indices) rawContent
  return (rawHeads, aligns, indices)

gridTableRawLine :: [Int] -> GenParser Char ParserState [String]
gridTableRawLine indices = do
  char '|'
  line <- many1Till anyChar newline
  return (gridTableSplitLine indices $ removeTrailingSpace line)

-- | Parse row of grid table.
gridTableRow :: GenParser Char ParserState Block
             -> [Int]
             -> GenParser Char ParserState [[Block]]
gridTableRow block indices = do
  colLines <- many1 (gridTableRawLine indices)
  let cols = map ((++ "\n") . unlines . removeOneLeadingSpace) $
               transpose colLines
  mapM (liftM compactifyCell . parseFromString (many block)) cols

removeOneLeadingSpace :: [String] -> [String]
removeOneLeadingSpace xs =
  if all startsWithSpace xs
     then map (drop 1) xs
     else xs
   where startsWithSpace ""     = True
         startsWithSpace (y:_) = y == ' '

compactifyCell :: [Block] -> [Block]
compactifyCell bs = head $ compactify [bs]

-- | Parse footer for a grid table.
gridTableFooter :: GenParser Char ParserState [Char]
gridTableFooter = blanklines

---

-- | Parse a string with a given parser and state.
readWith :: GenParser Char ParserState a      -- ^ parser
         -> ParserState                    -- ^ initial state
         -> String                         -- ^ input string
         -> a
readWith parser state input = 
    case runParser parser state "source" input of
      Left err     -> error $ "\nError:\n" ++ show err
      Right result -> result

-- | Parse a string with @parser@ (for testing).
testStringWith :: (Show a) => GenParser Char ParserState a
               -> String
               -> IO ()
testStringWith parser str = UTF8.putStrLn $ show $
                            readWith parser defaultParserState str

-- | Parsing options.
data ParserState = ParserState
    { stateParseRaw        :: Bool,          -- ^ Parse raw HTML and LaTeX?
      stateParserContext   :: ParserContext, -- ^ Inside list?
      stateQuoteContext    :: QuoteContext,  -- ^ Inside quoted environment?
      stateSanitizeHTML    :: Bool,          -- ^ Sanitize HTML?
      stateKeys            :: KeyTable,      -- ^ List of reference keys
#ifdef _CITEPROC
      stateCitations       :: [String],      -- ^ List of available citations
#endif
      stateNotes           :: NoteTable,     -- ^ List of notes
      stateTabStop         :: Int,           -- ^ Tab stop
      stateStandalone      :: Bool,          -- ^ Parse bibliographic info?
      stateTitle           :: [Inline],      -- ^ Title of document
      stateAuthors         :: [[Inline]],    -- ^ Authors of document
      stateDate            :: [Inline],      -- ^ Date of document
      stateStrict          :: Bool,          -- ^ Use strict markdown syntax?
      stateSmart           :: Bool,          -- ^ Use smart typography?
      stateLiterateHaskell :: Bool,          -- ^ Treat input as literate haskell
      stateColumns         :: Int,           -- ^ Number of columns in terminal
      stateHeaderTable     :: [HeaderType],  -- ^ Ordered list of header types used
      stateIndentedCodeClasses :: [String]   -- ^ Classes to use for indented code blocks
    }
    deriving Show

defaultParserState :: ParserState
defaultParserState = 
    ParserState { stateParseRaw        = False,
                  stateParserContext   = NullState,
                  stateQuoteContext    = NoQuote,
                  stateSanitizeHTML    = False,
                  stateKeys            = M.empty,
#ifdef _CITEPROC
                  stateCitations       = [],
#endif
                  stateNotes           = [],
                  stateTabStop         = 4,
                  stateStandalone      = False,
                  stateTitle           = [],
                  stateAuthors         = [],
                  stateDate            = [],
                  stateStrict          = False,
                  stateSmart           = False,
                  stateLiterateHaskell = False,
                  stateColumns         = 80,
                  stateHeaderTable     = [],
                  stateIndentedCodeClasses = [] }

data HeaderType 
    = SingleHeader Char  -- ^ Single line of characters underneath
    | DoubleHeader Char  -- ^ Lines of characters above and below
    deriving (Eq, Show)

data ParserContext 
    = ListItemState   -- ^ Used when running parser on list item contents
    | NullState       -- ^ Default state
    deriving (Eq, Show)

data QuoteContext
    = InSingleQuote   -- ^ Used when parsing inside single quotes
    | InDoubleQuote   -- ^ Used when parsing inside double quotes
    | NoQuote         -- ^ Used when not parsing inside quotes
    deriving (Eq, Show)

type NoteTable = [(String, String)]

newtype Key = Key [Inline] deriving (Show, Read)

instance Eq Key where
  Key a == Key b = refsMatch a b

instance Ord Key where
  compare (Key a) (Key b) = if a == b then EQ else compare a b

type KeyTable = M.Map Key Target

-- | Look up key in key table and return target object.
lookupKeySrc :: KeyTable  -- ^ Key table
             -> Key       -- ^ Key
             -> Maybe Target
lookupKeySrc table key = case M.lookup key table of
                           Nothing  -> Nothing
                           Just src -> Just src

-- | Returns @True@ if keys match (case insensitive).
refsMatch :: [Inline] -> [Inline] -> Bool
refsMatch ((Str x):restx) ((Str y):resty) = 
    ((map toLower x) == (map toLower y)) && refsMatch restx resty
refsMatch ((Emph x):restx) ((Emph y):resty) = 
    refsMatch x y && refsMatch restx resty
refsMatch ((Strong x):restx) ((Strong y):resty) = 
    refsMatch x y && refsMatch restx resty
refsMatch ((Strikeout x):restx) ((Strikeout y):resty) = 
    refsMatch x y && refsMatch restx resty
refsMatch ((Superscript x):restx) ((Superscript y):resty) = 
    refsMatch x y && refsMatch restx resty
refsMatch ((Subscript x):restx) ((Subscript y):resty) = 
    refsMatch x y && refsMatch restx resty
refsMatch ((SmallCaps x):restx) ((SmallCaps y):resty) = 
    refsMatch x y && refsMatch restx resty
refsMatch ((Quoted t x):restx) ((Quoted u y):resty) = 
    t == u && refsMatch x y && refsMatch restx resty
refsMatch ((Code x):restx) ((Code y):resty) = 
    ((map toLower x) == (map toLower y)) && refsMatch restx resty
refsMatch ((Math t x):restx) ((Math u y):resty) = 
    ((map toLower x) == (map toLower y)) && t == u && refsMatch restx resty
refsMatch ((TeX x):restx) ((TeX y):resty) = 
    ((map toLower x) == (map toLower y)) && refsMatch restx resty
refsMatch ((HtmlInline x):restx) ((HtmlInline y):resty) = 
    ((map toLower x) == (map toLower y)) && refsMatch restx resty
refsMatch (x:restx) (y:resty) = (x == y) && refsMatch restx resty
refsMatch [] x = null x
refsMatch x [] = null x
