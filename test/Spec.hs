{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Control.Monad          ((<=<))
import qualified Data.ByteString        as BS
import qualified Data.ByteString.Lazy   as BSL
import           Data.Foldable          (toList)
import           Data.Functor           (void)
import           Jacinda.AST
import           Jacinda.File
import           Jacinda.Parser
import           Jacinda.Parser.Rewrite
import           Jacinda.Regex
import           Jacinda.Ty.Const
import           Test.Tasty
import           Test.Tasty.HUnit

main :: IO ()
main = defaultMain $
    testGroup "Jacinda interpreter"
        [ testCase "parses no error" (parseNoErr sumBytes)
        , testCase "parse as" (parseTo sumBytes sumBytesAST)
        , testCase "parse as" (parseTo "#`0>72" pAst)
        , parseFile "test/examples/ab.jac"
        , splitWhitespaceT "1 1.3\tj" ["1", "1.3", "j"]
        , splitWhitespaceT
            "drwxr-xr-x  12 vanessa  staff   384 Dec 26 19:43 _darcs"
            ["drwxr-xr-x","12","vanessa","staff","384","Dec","26","19:43","_darcs"]
        , splitWhitespaceT "      55 ./src/Jacinda/File.hs" ["55", "./src/Jacinda/File.hs"]
        , splitWhitespaceT "" []
        , splitWhitespaceT "5" ["5"]
        , testCase "type of" (tyOfT sumBytes (TyB Star TyInteger))
        , testCase "type of" (tyOfT krakRegex (TyApp Star (TyB (KArr Star Star) TyStream) (TyB Star TyStr))) -- stream of str
        , testCase "type of" (tyOfT krakCol (TyApp Star (TyB (KArr Star Star) TyStream) (TyB Star TyStr))) -- stream of str
        , testCase "type of (zip)" (tyOfT ",(-) $3:i $6:i" (tyStream tyI))
        , testCase "type of (filter)" (tyOfT "(>110) #. #\"$0" (tyStream tyI))
        , testCase "typechecks dfn" (tyOfT "[(+)|0 x] $1:i" tyI)
        , testCase "count bytes" (tyOfT "(+)|0 #\"$0" tyI)
        , testCase "running count (lines)" (tyOfT "(+)^0 [:1\"$0" (tyStream tyI))
        , testCase "type of (tally)" (tyOfT "#'hello world'" tyI)
        , testCase "typechecks dfn" (tyFile "test/examples/ab.jac")
        , testCase "parses parens" (tyFile "examples/lib.jac")
        , testCase "typechecks/parses correctly" (tyFile "test/examples/line.jac")
        , testCase "split eval" (evalTo "[x+' '+y]|> split '01-23-1987' /-/" "01 23 1987")
        , testCase "length eval" (evalTo "#*split '01-23-1987' /-/" "3")
        , testCase "captureE" (evalTo "'01-23-1987' ~* 3 /(\\d{2})-(\\d{2})-(\\d{4})/" "Some 1987")
        , testCase "if...then...else" (evalTo "if #t then 0 else 1" "0")
        ]

evalTo :: BSL.ByteString -> String -> Assertion
evalTo bsl expected =
    let actual = show (exprEval bsl)
        in actual @?= expected

pAst :: E ()
pAst =
    EApp ()
        (EApp ()
            (BB () Gt)
            (EApp ()
                (UB () Tally)
                (AllField ())))
        (IntLit () 72)

splitWhitespaceT :: BS.ByteString -> [BS.ByteString] -> TestTree
splitWhitespaceT haystack expected =
    testCase "split col" $
        toList (splitBy defaultRurePtr haystack) @?= expected

-- example: ls -l | ja '(+)|0 $5:i'
sumBytes :: BSL.ByteString
sumBytes = "(+)|0 $5:i"

krakRegex :: BSL.ByteString
krakRegex = "{% /Krakatoa/}{`0}"

krakCol :: BSL.ByteString
krakCol = "{`3:i > 4}{`0}"

sumBytesAST :: E ()
sumBytesAST =
    EApp ()
        (EApp ()
            (EApp ()
                (TB () Fold)
                (BB () Plus))
            (IntLit () 0))
            (IParseCol () 5)

tyFile :: FilePath -> Assertion
tyFile = tcIO [] <=< BSL.readFile

tyOfT :: BSL.ByteString -> T K -> Assertion
tyOfT src expected =
    tySrc src @?= expected

parseTo :: BSL.ByteString -> E () -> Assertion
parseTo src e =
    case rewriteProgram . snd <$> parse src of
        Left err     -> assertFailure (show err)
        Right actual -> void (expr actual) @?= e

parseFile :: FilePath -> TestTree
parseFile fp = testCase ("Parses " ++ fp) $ parseNoErr =<< BSL.readFile fp

parseNoErr :: BSL.ByteString -> Assertion
parseNoErr src =
    case parse src of
        Left err -> assertFailure (show err)
        Right{}  -> assertBool "success" True
