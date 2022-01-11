{-# LANGUAGE OverloadedStrings #-}

-- TODO: test this module?
module Jacinda.Backend.Normalize ( compileR
                                 , compileIn
                                 , eClosed
                                 , closedProgram
                                 , readDigits
                                 , readFloat
                                 , mkI
                                 , mkF
                                 , mkStr
                                 , parseAsEInt
                                 , parseAsF
                                 , the
                                 , asTup
                                 ) where

import           Control.Monad.State.Strict (State, evalState, gets, modify)
import           Control.Recursion          (cata, embed)
import qualified Data.ByteString            as BS
import qualified Data.ByteString.Char8      as ASCII
import           Data.Foldable              (traverse_)
import qualified Data.IntMap                as IM
import           Data.Semigroup             ((<>))
import qualified Data.Vector                as V
import           Data.Word                  (Word8)
import           Intern.Name
import           Intern.Unique
import           Jacinda.AST
import           Jacinda.Backend.Printf
import           Jacinda.Regex
import           Jacinda.Rename
import           Jacinda.Ty.Const
import           Regex.Rure                 (RureMatch (..))

mkI :: Integer -> E (T K)
mkI = IntLit tyI

mkF :: Double -> E (T K)
mkF = FloatLit tyF

mkStr :: BS.ByteString -> E (T K)
mkStr = StrLit tyStr

parseAsEInt :: BS.ByteString -> E (T K)
parseAsEInt = mkI . readDigits

parseAsF :: BS.ByteString -> E (T K)
parseAsF = FloatLit tyF . readFloat

readDigits :: BS.ByteString -> Integer
readDigits = ASCII.foldl' (\seed x -> 10 * seed + f x) 0
    where f '0' = 0
          f '1' = 1
          f '2' = 2
          f '3' = 3
          f '4' = 4
          f '5' = 5
          f '6' = 6
          f '7' = 7
          f '8' = 8
          f '9' = 9
          f c   = error (c:" is not a valid digit!")

the :: BS.ByteString -> Word8
the bs = case BS.uncons bs of
    Nothing     -> error "Empty splitc char!"
    Just (c,"") -> c
    Just _      -> error "Splitc takes only one char!"

readFloat :: BS.ByteString -> Double
readFloat = read . ASCII.unpack

-- fill in regex with compiled.
compileR :: E a
         -> E a
compileR = cata a where -- TODO: combine with eNorm pass?
    a (RegexLitF _ rr) = RegexCompiled (compileDefault rr)
    a x                = embed x

compileIn :: Program a -> Program a
compileIn (Program ds e) = Program (compileD <$> ds) (compileR e)

compileD :: D a -> D a
compileD d@SetFS{}       = d
compileD (FunDecl n l e) = FunDecl n l (compileR e)

desugar :: a
desugar = error "Should have been desugared by this stage."

data LetCtx = LetCtx { binds    :: IM.IntMap (E (T K))
                     , renames_ :: Renames
                     }

instance HasRenames LetCtx where
    rename f s = fmap (\x -> s { renames_ = x }) (f (renames_ s))

mapBinds :: (IM.IntMap (E (T K)) -> IM.IntMap (E (T K))) -> LetCtx -> LetCtx
mapBinds f (LetCtx b r) = LetCtx (f b) r

type EvalM = State LetCtx

mkLetCtx :: Int -> LetCtx
mkLetCtx i = LetCtx IM.empty (Renames i IM.empty)

eClosed :: Int
        -> E (T K)
        -> E (T K)
eClosed i = flip evalState (mkLetCtx i) . eNorm

closedProgram :: Int
              -> Program (T K)
              -> E (T K)
closedProgram i (Program ds e) = flip evalState (mkLetCtx i) $
    traverse_ processDecl ds *>
    eNorm e

processDecl :: D (T K)
            -> EvalM ()
processDecl SetFS{} = pure ()
processDecl (FunDecl (Name _ (Unique i) _) [] e) = do
    e' <- eNorm e
    modify (mapBinds (IM.insert i e'))

asTup :: Maybe RureMatch -> E (T K)
asTup Nothing                = OptionVal undefined Nothing
asTup (Just (RureMatch s e)) = OptionVal undefined (Just $ Tup undefined (mkI . fromIntegral <$> [s, e]))

-- TODO: equality on tuples, lists
eNorm :: E (T K)
      -> EvalM (E (T K))
eNorm e@Field{}       = pure e
eNorm e@IntLit{}      = pure e
eNorm e@FloatLit{}    = pure e
eNorm e@BoolLit{}     = pure e
eNorm e@StrLit{}      = pure e
eNorm e@RegexLit{}    = pure e
eNorm e@RegexCompiled{} = pure e
eNorm e@UBuiltin{}    = pure e
eNorm e@Column{}      = pure e
eNorm e@AllColumn{}   = pure e
eNorm e@IParseCol{}   = pure e
eNorm e@FParseCol{}   = pure e
eNorm e@AllField{}    = pure e
eNorm (Guarded ty pe e) = Guarded ty <$> eNorm pe <*> eNorm e
eNorm (Implicit ty e) = Implicit ty <$> eNorm e
eNorm (Lam ty n e)    = Lam ty n <$> eNorm e
eNorm e@BBuiltin{}    = pure e
eNorm e@TBuiltin{}    = pure e
eNorm (Tup tys es)    = Tup tys <$> traverse eNorm es
eNorm e@Ix{}          = pure e
eNorm (EApp ty op@BBuiltin{} e) = EApp ty op <$> eNorm e
eNorm (EApp ty (EApp ty' op@(BBuiltin _ Matches) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (RegexCompiled re, StrLit _ str) -> BoolLit tyBool (isMatch' re str)
        (StrLit _ str, RegexCompiled re) -> BoolLit tyBool (isMatch' re str)
        _                                -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin _ NotMatches) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (RegexCompiled re, StrLit _ str) -> BoolLit tyBool (not $ isMatch' re str)
        (StrLit _ str, RegexCompiled re) -> BoolLit tyBool (not $ isMatch' re str)
        _                                -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty0 (EApp ty1 op@(BBuiltin (TyArr _ (TyB _ TyInteger) _) Plus) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (IntLit _ i, IntLit _ j) -> i `seq` j `seq` IntLit tyI (i+j)
        _                        -> EApp ty0 (EApp ty1 op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyStr) _) Plus) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (StrLit _ s, StrLit _ s')       -> StrLit tyStr (s <> s')
        (RegexLit _ rr, RegexLit _ rr') -> RegexLit tyStr (rr <> rr')
        _                               -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyInteger) _) Max) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (IntLit _ i, IntLit _ j) -> i `seq` j `seq` IntLit tyI (max i j)
        _                        -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyInteger) _) Min) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (IntLit _ i, IntLit _ j) -> i `seq` j `seq` IntLit tyI (min i j)
        _                        -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyFloat) _) Max) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (FloatLit _ x, FloatLit _ y) -> x `seq` y `seq` FloatLit tyF (max x y)
        _                            -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyFloat) _) Min) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (FloatLit _ x, FloatLit _ y) -> x `seq` y `seq` FloatLit tyF (min x y)
        _                            -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin _ Split) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (StrLit l str, RegexCompiled re) -> let bss = splitBy re str in Arr undefined (StrLit l <$> bss)
        _                                -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin _ Splitc) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (StrLit l str, StrLit _ c) -> let bss = BS.split (the c) str in Arr undefined (StrLit l <$> V.fromList bss)
        _                          -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty op@(UBuiltin _ Floor) e) = do
    eI <- eNorm e
    pure $ case eI of
        (FloatLit _ f) -> mkI (floor f)
        _              -> EApp ty op eI
eNorm (EApp ty op@(UBuiltin _ Ceiling) e) = do
    eI <- eNorm e
    pure $ case eI of
        (FloatLit _ f) -> mkI (ceiling f)
        _              -> EApp ty op eI
eNorm (EApp ty0 (EApp ty1 op@(BBuiltin (TyArr _ (TyB _ TyInteger) _) Minus) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (IntLit _ i, IntLit _ j) -> i `seq` j `seq` IntLit tyI (i-j)
        _                        -> EApp ty0 (EApp ty1 op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyInteger) _) Times) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (IntLit _ i, IntLit _ j) -> i `seq` j `seq` IntLit tyI (i*j)
        _                        -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyFloat) _) Plus) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (FloatLit _ i, FloatLit _ j) -> i `seq` j `seq` FloatLit tyF (i+j)
        _                            -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyFloat) _) Minus) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (FloatLit _ i, FloatLit _ j) -> i `seq` j `seq` FloatLit tyF (i-j)
        _                            -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyFloat) _) Times) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (FloatLit _ i, FloatLit _ j) -> i `seq` j `seq` FloatLit tyF (i*j)
        _                            -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyFloat) _) Div) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (FloatLit _ i, FloatLit _ j) -> i `seq` j `seq` FloatLit tyF (i/j)
        _                            -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (UBuiltin ty' Tally) e) = do
    eI <- eNorm e
    pure $ case eI of
        StrLit _ str -> IntLit tyI (fromIntegral $ BS.length str)
        _            -> EApp ty (UBuiltin ty' Tally) eI
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyStr) _) Eq) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (StrLit _ i, StrLit _ j) -> BoolLit tyBool (i == j)
        _                        -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyInteger) _) Lt) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (IntLit _ i, IntLit _ j) -> BoolLit tyBool (i < j)
        _                        -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyInteger) _) Gt) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (IntLit _ i, IntLit _ j) -> BoolLit tyBool (i > j)
        _                        -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyInteger) _) Eq) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (IntLit _ i, IntLit _ j) -> BoolLit tyBool (i == j)
        _                        -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyInteger) _) Neq) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (IntLit _ i, IntLit _ j) -> BoolLit tyBool (i /= j)
        _                        -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyInteger) _) Leq) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (IntLit _ i, IntLit _ j) -> BoolLit tyBool (i <= j)
        _                        -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyInteger) _) Geq) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (IntLit _ i, IntLit _ j) -> BoolLit tyBool (i >= j)
        _                        -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyFloat) _) Eq) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (FloatLit _ i, FloatLit _ j) -> BoolLit tyBool (i == j)
        _                            -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyFloat) _) Neq) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (FloatLit _ i, FloatLit _ j) -> BoolLit tyBool (i /= j)
        _                            -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyFloat) _) Leq) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (FloatLit _ i, FloatLit _ j) -> BoolLit tyBool (i <= j)
        _                            -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyFloat) _) Geq) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (FloatLit _ i, FloatLit _ j) -> BoolLit tyBool (i >= j)
        _                            -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyFloat) _) Gt) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (FloatLit _ i, FloatLit _ j) -> BoolLit tyBool (i > j)
        _                            -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyFloat) _) Lt) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (FloatLit _ i, FloatLit _ j) -> BoolLit tyBool (i < j)
        _                            -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty (EApp ty' op@(BBuiltin (TyArr _ (TyB _ TyStr) _) Neq) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (StrLit _ i, StrLit _ j) -> BoolLit tyBool (i /= j)
        _                        -> EApp ty (EApp ty' op eI) eI'
eNorm (EApp ty0 (EApp ty1 op@(BBuiltin _ And) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (BoolLit _ b, BoolLit _ b') -> b `seq` b' `seq` BoolLit tyBool (b && b')
        _                           -> EApp ty0 (EApp ty1 op eI) eI'
eNorm (EApp ty0 (EApp ty1 op@(BBuiltin _ Or) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (BoolLit _ b, BoolLit _ b') -> b `seq` b' `seq` BoolLit tyBool (b || b')
        _                           -> EApp ty0 (EApp ty1 op eI) eI'
eNorm (EApp _ (EApp _ (UBuiltin _ Const) e) _) = eNorm e
eNorm (EApp ty op@(UBuiltin _ Const) e) = EApp ty op <$> eNorm e
eNorm (EApp ty op@(UBuiltin _ (At i)) e) = do
    eI <- eNorm e
    pure $ case eI of
        (Arr _ es) -> es V.! (i-1)
        _          -> EApp ty op eI
eNorm (EApp ty op@(UBuiltin _ (Select i)) e) = do
    eI <- eNorm e
    pure $ case eI of
        (Tup _ es) -> es !! (i-1)
        _          -> EApp ty op eI
eNorm (EApp ty op@(UBuiltin _ Not) e) = do
    eI <- eNorm e
    pure $ case eI of
        (BoolLit _ b) -> BoolLit tyBool (not b)
        _             -> EApp ty op eI
eNorm (EApp ty op@(UBuiltin _ IParse) e) = do
    eI <- eNorm e
    pure $ case eI of
        (StrLit _ str) -> parseAsEInt str
        _              -> EApp ty op eI
eNorm (EApp ty op@(UBuiltin _ FParse) e) = do
    eI <- eNorm e
    pure $ case eI of
        (StrLit _ str) -> parseAsF str
        _              -> EApp ty op eI
eNorm Dfn{} = desugar
eNorm ResVar{} = desugar
eNorm (Let _ (Name _ (Unique i) _, b) e) = do
    b' <- eNorm b
    modify (mapBinds (IM.insert i b'))
    eNorm e
eNorm e@(Var _ (Name _ (Unique i) _)) = do
    st <- gets binds
    case IM.lookup i st of
        Just e'@Var{} -> eNorm e' -- no cyclic binds!!
        Just e'       -> renameE e'
        Nothing       -> pure e -- default to e in case var was bound in a lambda
eNorm (EApp ty e@Var{} e') = eNorm =<< (EApp ty <$> eNorm e <*> pure e')
eNorm (EApp _ (Lam _ (Name _ (Unique i) _) e) e') = do
    e'' <- eNorm e'
    modify (mapBinds (IM.insert i e''))
    eNorm e
eNorm (EApp ty0 (EApp ty1 (EApp ty2 (TBuiltin ty3 Substr) e0) e1) e2) = do
    e0' <- eNorm e0
    e1' <- eNorm e1
    e2' <- eNorm e2
    pure $ case (e0', e1', e2') of
        (StrLit _ str, IntLit _ i, IntLit _ j) -> mkStr (substr str (fromIntegral i) (fromIntegral j))
        _                                      -> EApp ty0 (EApp ty1 (EApp ty2 (TBuiltin ty3 Substr) e0') e1') e2'
eNorm (EApp ty0 (EApp ty1 (EApp ty2 op@(TBuiltin _ Option) e0) e1) e2) = do
    e0' <- eNorm e0
    e1' <- eNorm e1
    e2' <- eNorm e2
    case e2' of
        (OptionVal _ Nothing)  -> pure e0'
        (OptionVal _ (Just e)) -> eNorm (EApp undefined e1' e)
        _                      -> pure $ EApp ty0 (EApp ty1 (EApp ty2 op e0') e1') e2'
eNorm (EApp ty0 (EApp ty1 op@(BBuiltin _ Match) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (StrLit _ str, RegexCompiled re) -> asTup (find' re str)
        _                                -> EApp ty0 (EApp ty1 op eI) eI'
eNorm (EApp ty0 (EApp ty1 op@(BBuiltin _ Sprintf) e) e') = do
    eI <- eNorm e
    eI' <- eNorm e'
    pure $ case (eI, eI') of
        (StrLit _ fmt, _) | isReady eI' -> mkStr $ sprintf fmt eI'
        _                               -> EApp ty0 (EApp ty1 op eI) eI'
eNorm (EApp ty0 (EApp ty1 (EApp ty2 op@TBuiltin{} f) x) y) = EApp ty0 <$> (EApp ty1 <$> (EApp ty2 op <$> eNorm f) <*> eNorm x) <*> eNorm y
eNorm (EApp ty0 (EApp ty1 op@(BBuiltin _ Prior) x) y) = EApp ty0 <$> (EApp ty1 op <$> eNorm x) <*> eNorm y
eNorm (EApp ty0 (EApp ty1 op@(BBuiltin _ Map) x) y) = EApp ty0 <$> (EApp ty1 op <$> eNorm x) <*> eNorm y
eNorm (EApp ty0 (EApp ty1 op@(BBuiltin _ Filter) x) y) = EApp ty0 <$> (EApp ty1 op <$> eNorm x) <*> eNorm y
-- FIXME: this will almost surely run into trouble; if the above pattern matches
-- are not complete it will bottom!
eNorm (EApp ty e@EApp{} e') =
    eNorm =<< (EApp ty <$> eNorm e <*> pure e')
eNorm (Arr ty es) = Arr ty <$> traverse eNorm es
