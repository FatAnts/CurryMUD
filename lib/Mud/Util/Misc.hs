{-# OPTIONS_GHC -funbox-strict-fields -Wall -Werror #-}
{-# LANGUAGE OverloadedStrings, ViewPatterns #-}

module Mud.Util.Misc ( aOrAn
                     , appendIfUnique
                     , blowUp
                     , capitalize
                     , countOcc
                     , dropBlanks
                     , dup
                     , eitherRet
                     , findFullNameForAbbrev
                     , headTail
                     , headTail'
                     , ifThenElse
                     , isVowel
                     , maybeRet
                     , maybeVoid
                     , mkCountList
                     , mkOrdinal
                     , mkTimestamp
                     , nl
                     , nl'
                     , nlnl
                     , notInfixOf
                     , nubSort
                     , patternMatchFail
                     , reverseLookup
                     , showText
                     , stripControl
                     , stripTelnet
                     , toMaybe
                     , uncapitalize ) where

import Mud.TopLvlDefs.Chars
import Mud.Util.Quoting

import Control.Applicative ((<$>), (<*>))
import Control.Arrow ((***))
import Control.Monad (guard)
import Data.Char (toLower, toUpper)
import Data.List (foldl', sort)
import Data.Monoid ((<>))
import Data.Time (getZonedTime)
import qualified Data.Map.Lazy as M (Map, assocs)
import qualified Data.Set as S (fromList, toList)
import qualified Data.Text as T


aOrAn :: T.Text -> T.Text
aOrAn (T.strip -> t) | T.null t             = ""
                     | isVowel . T.head $ t = "an " <> t
                     | otherwise            = "a "  <> t


appendIfUnique :: (Eq a) => [a] -> a -> [a]
xs `appendIfUnique` x | x `elem` xs = xs
                      | otherwise   = xs ++ [x]


blowUp :: T.Text -> T.Text -> T.Text -> [T.Text] -> a
blowUp modName funName msg (bracketQuote . T.intercalate ", " . map singleQuote -> vals) =
    error . T.unpack . T.concat $ [ modName, " ", funName, ": ", msg, ". ", vals ]


capitalize :: T.Text -> T.Text
capitalize = capsHelper toUpper


uncapitalize :: T.Text -> T.Text
uncapitalize = capsHelper toLower


capsHelper :: (Char -> Char) -> T.Text -> T.Text
capsHelper f (headTail' -> (T.singleton . f -> h, t)) = h <> t


countOcc :: (Eq a) => a -> [a] -> Int
countOcc needle = foldl' (\acc x -> if x == needle then succ acc else acc) 0


dropBlanks :: [T.Text] -> [T.Text]
dropBlanks []      = []
dropBlanks ("":xs) =     dropBlanks xs
dropBlanks ( x:xs) = x : dropBlanks xs


dup :: a -> (a, a)
dup x = (x, x)


eitherRet :: (Monad m) => (a -> m b) -> Either a b -> m b
eitherRet = flip either return


findFullNameForAbbrev :: T.Text -> [T.Text] -> Maybe T.Text
findFullNameForAbbrev needle hay = guard (not . null $ res) >> (Just . head $ res)
  where
    res = sort . filter (needle `T.isPrefixOf`) $ hay


headTail :: [a] -> (a, [a])
headTail = (,) <$> head <*> tail


headTail' :: T.Text -> (Char, T.Text)
headTail' = (T.head *** T.tail) . dup


ifThenElse :: Bool -> a -> a -> a
ifThenElse True  x _ = x
ifThenElse False _ y = y


isVowel :: Char -> Bool
isVowel = (`elem` "aeiou")


maybeRet :: Monad m => m a -> Maybe a -> m a
maybeRet dflt = maybe dflt return


maybeVoid :: (Monad m) => (a -> m ()) -> Maybe a -> m ()
maybeVoid = maybe (return ())


mkCountList :: (Eq a) => [a] -> [Int]
mkCountList xs = map (`countOcc` xs) xs


mkOrdinal :: Int -> T.Text
mkOrdinal 11              = "11th"
mkOrdinal 12              = "12th"
mkOrdinal 13              = "13th"
mkOrdinal (showText -> n) = n <> case T.last n of '1' -> "st"
                                                  '2' -> "nd"
                                                  '3' -> "rd"
                                                  _   -> "th"


mkTimestamp :: IO T.Text
mkTimestamp = getZonedTime >>= \(T.words . showText -> wordy) ->
    let date = head wordy
        time = T.init . T.reverse . T.dropWhile (/= '.') . T.reverse . head . tail $ wordy
    in return . bracketQuote $ date <> " " <> time


nl :: T.Text -> T.Text
nl = (<> "\n")


nlnl :: T.Text -> T.Text
nlnl = nl . nl


nl' :: T.Text -> T.Text
nl' = ("\n" <>)


notInfixOf :: T.Text -> T.Text -> Bool
notInfixOf needle haystack = not $  needle `T.isInfixOf` haystack


nubSort :: (Ord a) => [a] -> [a]
nubSort = S.toList . S.fromList


patternMatchFail :: T.Text -> T.Text -> [T.Text] -> a
patternMatchFail modName funName = blowUp modName funName "pattern match failure"


reverseLookup :: (Eq v) => v -> M.Map k v -> k
reverseLookup v = fst . head . filter ((== v) . snd) . M.assocs


showText :: (Show a) => a -> T.Text
showText = T.pack . show


stripControl :: T.Text -> T.Text
stripControl = T.filter (\c -> c > '\31' && c < '\127')


stripTelnet :: T.Text -> T.Text
stripTelnet t
  | T.singleton telnetIAC `T.isInfixOf` t, (left, right) <- T.breakOn (T.singleton telnetIAC) t = left <> helper right
  | otherwise = t
  where
    helper (T.uncons -> Just (_, T.uncons -> Just (x, T.uncons -> Just (_, rest))))
      | x == telnetSB = case T.breakOn (T.singleton telnetSE) rest of (_, "")              -> ""
                                                                      (_, T.tail -> rest') -> stripTelnet rest'
      | otherwise     = stripTelnet rest
    helper _ = ""


toMaybe :: Bool -> a -> Maybe a
toMaybe False _ = Nothing
toMaybe True  a = Just a
