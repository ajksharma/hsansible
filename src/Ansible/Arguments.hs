{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
-- |
-- Module:       $HEADER$
-- Description:  Interface for parsing Ansible module argument.
-- Copyright:    (c) 2013, 2015, Peter Trško
-- License:      BSD3
--
-- Maintainer:   peter.trsko@gmail.com
-- Stability:    experimental
-- Portability:  CPP, DeriveDataTypeable, NoImplicitPrelude, OverloadedStrings,
--               RecordWildCards
--
-- Interface for parsing Ansible module arguments.
module Ansible.Arguments
    (
    -- * Generic arugment parsing interface
      ParseArguments(..)
    , readArgumentsFile

    -- * Concrete parsing implementations
    , RawArguments(..)
    , StdArguments(..)

    -- ** Standard arguments parser
    , parseStdArguments
    , stdArgumentsParser

    -- * Utility functions
    , castBool
    , fromPairs
    )
  where

-- {{{ Imports ----------------------------------------------------------------

import Control.Applicative (Applicative(..), Alternative((<|>)), (<$>), liftA2)
import Control.Monad (Monad(fail, return), liftM2)
import Data.Bool (Bool(False, True), (&&), (||), not, otherwise)
import Data.Data (Data, Typeable)
import Data.Either (Either(Left, Right))
import Data.Eq (Eq((==), (/=)))
import Data.Function ((.), ($))
import Data.List (foldl', map)
import Data.Maybe (Maybe(Just, Nothing))
import Data.Monoid (Monoid(..))
import Data.Ord (Ord((<=), (>=)))
import Data.String (String)
import Data.Tuple (uncurry)
import Data.Word (Word8)
import System.IO (FilePath)
import Text.Read (Read)
import Text.Show (Show)

import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Trans.Except (ExceptT)
import Data.Aeson ((.=), ToJSON(..))
import qualified Data.Aeson as JSON
import Data.Attoparsec.ByteString (Parser, satisfy, skipWhile, word8)
import Data.Attoparsec.ByteString.Char8 (isDigit_w8, isSpace_w8)
import Data.Attoparsec.Combinator (many1, option, sepBy1)
import qualified Data.Attoparsec.ByteString as Attoparsec
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.CaseInsensitive as CI
import Data.Text (Text)
import qualified Data.Text as Text (empty)
import qualified Data.Text.Encoding as Text (decodeUtf8)

import Ansible.Failure (Failure)

-- }}} Imports ----------------------------------------------------------------

-- {{{ Generic argument parsing interface -------------------------------------

class ParseArguments a where
    -- | Either return error message or parse arguments.
    parseArguments :: ByteString -> Either String a

-- | This is the main purpose of arguments parsing interface. To read and parse
-- arguments file passed on by the Ansible as an command line argument.
readArgumentsFile
    :: (MonadIO m, ParseArguments a)
    => FilePath
    -> ExceptT Failure m a
readArgumentsFile fp = do
    content <- liftIO $ BS.readFile fp
    case parseArguments content of
        Left msg -> fail msg
        Right x  -> return x

-- }}} Generic argument parsing interface -------------------------------------

-- {{{ Concrete parsing implementations ---------------------------------------
-- {{{ Concrete parsing implementations: RawArguments -------------------------

-- | This newtype allows modules to have access to unparsed content of
-- arguments file.
newtype RawArguments = RawArguments {rawArguments :: Text}
    deriving (Data, Eq, Show, Read, Typeable)

instance ParseArguments RawArguments where
    parseArguments = Right . RawArguments . Text.decodeUtf8

instance ToJSON RawArguments where
    toJSON RawArguments{..} = toJSON rawArguments

-- }}} Concrete parsing implementations: RawArguments -------------------------

-- {{{ Concrete parsing implementations: StdArguments -------------------------

-- | Wrapper for list of simple @key=value@ pairs where value is optional. This
-- is the most common way how modules interpret their arguments.
newtype StdArguments = StdArguments {stdArguments :: [(Text, Maybe Text)]}
    deriving (Data, Eq, Show, Read, Typeable)

instance ParseArguments StdArguments where
    parseArguments bs = case parseStdArguments bs of
        Nothing  -> Left "Parsing of rguments failed."
        Just std -> Right $ StdArguments std

instance ToJSON StdArguments where
    toJSON StdArguments{..} = JSON.object $ map (uncurry (.=)) stdArguments

-- }}} Concrete parsing implementations: StdArguments -------------------------

-- {{{ Concrete parsing implementations: Standard arguments parser ------------

-- | Wrapper for 'stdArgumentsParser' that either produces parsed list of
-- key=value pairs or 'Noting'. This function is used by the 'ParseArguments'
-- instance for 'StdArguments'.
parseStdArguments :: ByteString -> Maybe [(Text, Maybe Text)]
parseStdArguments bs =
    -- Attoparsec.takeWhile1 fails at the end of input so we need to give it
    -- something to terminate on, hence the newline.
    case Attoparsec.feed (Attoparsec.parse parser bs) "\n" of
        Attoparsec.Done _ x -> Just x
        _                   -> Nothing
  where
    skipWhiteSpace = skipWhile $ \ch -> ch == 9 || ch == 32
    parser = skipWhiteSpace *> stdArgumentsParser <* skipWhiteSpace <* word8 10

-- | Parse @key=value@ pairs passed as a white space separated list. Note that
-- doe to using Attoparsec.takeWhile1 it will fail on end of input.
--
-- > <white-space>  := [\t ]
-- > <key>          := [0-9a-zA-Z_-]+
-- > <escape>       := "\" [trn0\"' ]
-- > <simple-value> := (<printable> \ <white-space> \ ["'] | <escape>)*
-- > <quoted-value> := '"' (<printable> \ ["] | <escape>)* '"'
-- >                |  "'" (<printable> \ ['] | <escape>)* "'"
-- > <value>        := (<simple-value> | <quoted-value>)?
-- > <key-value>    := <key> ("=" <value>)?
-- > <arguments>    := (<white-space>* <key-value>)* <white-space>*
stdArgumentsParser :: Parser [(Text, Maybe Text)]
stdArgumentsParser = option [] $ keyValuePair `sepBy1` many1 whiteSpace
  where
    -- If '=' character is not present, then Nothing is returned as a value.
    --
    -- <key> := ("=" value)?
    keyValuePair :: Parser (Text, Maybe Text)
    keyValuePair = (,) <$> key <*> option Nothing (Just <$> (word8 61 *> value))

    -- Key may consist only of: a-zA-Z0-9_-
    key :: Parser Text
    key = Text.decodeUtf8
        <$> Attoparsec.takeWhile1 (isAlphaNum <||> (== 45) <||> (== 95))

    -- Value is optional, but when '=' is already there, then we treat it as a
    -- empty string.
    --
    -- <value> := (<simple-value> | <quoted-value>)?
    value :: Parser Text
    value = option Text.empty
        $ Text.decodeUtf8 <$> (quotedValue <|> simpleValue)

    quotedValue :: Parser ByteString
    quotedValue = quotedValue' 39 <|> quotedValue' 34 -- '\'' or '"'

    quotedValue' :: Word8 -> Parser ByteString
    quotedValue' q = word8 q *> quotedValue'' q <* word8 q

    -- It would be best to limit characters to printable, but that's not
    -- possible in a simple manner due to UTF8.
    quotedValue'' :: Word8 -> Parser ByteString
    quotedValue'' q = option BS.empty $ BS.concat <$> many1
        (Attoparsec.takeWhile1 ((/= q) <&&> (/= 92)) <|> escape)

    simpleValue :: Parser ByteString
    simpleValue = BS.concat <$> many1
        (Attoparsec.takeWhile1
            ((not . isSpace_w8) <&&> (/= 34) <&&> (/= 39) <&&> (/= 92))
        <|> escape)

    escape :: Parser ByteString
    escape = mapEscape <$> (word8 92 *> satisfy isEscape)

    mapEscape :: Word8 -> ByteString
    mapEscape x = BS.singleton $ case x of
        48  -> 0   -- \0
        110 -> 10  -- \n
        114 -> 13  -- \r
        116 -> 9   -- \t
        _   -> x   -- \" \' \\ "\ "

    whiteSpace :: Parser Word8
    whiteSpace = satisfy ((== 9) <||> (== 32))  -- ' ' or '\t'

    isAlphaNum, isEscape :: Word8 -> Bool
    isAlphaNum = isDigit_w8 <||> ((>= 65) <&&> (<= 90))
        <||> ((>= 97) <&&> (<= 122))
        -- >= '0' && <= '9' || >= 'a' && <= 'z' || >= 'A' && <= 'Z'
    isEscape = (== 92) <||> (== 110) <||> (== 114) <||> (== 116) <||> (== 34)
        <||> (== 32) <||> (== 48) <||> (== 39)
        -- any of: 't', 'r', 'n', '0', '"', '\'', '\\', '\ '

    (<||>), (<&&>) :: Applicative f => f Bool -> f Bool -> f Bool
    (<||>) = liftA2 (||)
    infixr 2 <||>
    (<&&>) = liftA2 (&&)
    infixr 3 <&&>

-- }}} Concrete parsing implementations: Standard arguments parser ------------
-- }}} Concrete parsing implementations ---------------------------------------

-- {{{ Utility functions ------------------------------------------------------

-- | As a convinience boolean values are passed as string. This function tries,
-- hence the 'Maybe', to interpret it as a 'Bool'. It understands these values:
--
-- * "yes"/"no"
--
-- * "true"/"false"
--
-- * "1"/"0"
castBool :: Text -> Maybe Bool
castBool = castBool' . CI.mk
  where
    castBool' t
      | t == "yes" = Just True
      | t == "no" = Just False
      | t == "true" = Just True
      | t == "false" = Just False
      | t == "1" = Just True
      | t == "0" = Just False
      | otherwise = Nothing

-- | This function can be used to construct data types, that have Monoid
-- instance, from key-value pairs. So if we have some data type @Config@ that
-- has a 'Monoid' instance, then we can have:
--
-- > parseArguments >=> fromPairs pairToConfig . stdArguments
-- >     :: ByteString -> Either String Config
--
-- Above example requires 'Monad' instance for 'Either' which is defined in
-- @Control.Monad.Instances@.
fromPairs
    :: (Monad m, Monoid a)
    => (Text -> Maybe Text -> m a)
    -> [(Text, Maybe Text)]
    -> m a
fromPairs f = foldl' (\x -> liftM2 mappend x . uncurry f) $ return mempty

-- }}} Utility functions ------------------------------------------------------
