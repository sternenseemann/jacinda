{-# LANGUAGE FlexibleContexts #-}

module Jacinda.AST.I ( RM
                     , ib
                     ) where

import           Control.Monad.State.Strict (MonadState, State, gets, modify, runState)
import           Data.Bifunctor             (second)
import           Data.Foldable              (traverse_)
import qualified Data.IntMap                as IM
import           Intern.Name
import           Intern.Unique
import           Jacinda.AST
import           Jacinda.Rename
import           Jacinda.Ty

data ISt a = ISt { renames :: !Renames
                 , binds   :: IM.IntMap (E a)
                 }

instance HasRenames (ISt a) where
    rename f s = fmap (\x -> s { renames = x }) (f (renames s))

type RM a = State (ISt a)

bind :: Nm a -> E a -> ISt a -> ISt a
bind (Nm _ (U u) _) e (ISt r bs) = ISt r (IM.insert u e bs)

runI i = second (max_.renames) . flip runState (ISt (Renames i mempty) mempty)

ib :: Int -> Program (T K) -> (E (T K), Int)
ib i = uncurry (flip β).runI i.iP where iP (Program ds e) = traverse_ iD ds *> iE e

β :: Int -> E a -> (E a, Int)
β i = runI i.bM

iD :: D (T K) -> RM (T K) ()
iD (FunDecl n [] e) = do {eI <- iE e; modify (bind n eI)}
iD SetFS{}          = pure ()
iD FlushDecl{}      = pure ()
iD FunDecl{}        = desugar

desugar = error "Internal error. Should have been de-sugared in an earlier stage!"

bM :: (MonadState (ISt a) m) => E a -> m (E a)
bM (EApp _ (Lam _ n e') e) = do
    eI <- bM e
    modify (bind n eI) *> bM e'
bM (EApp l e0 e1) = do
    e0' <- bM e0
    e1' <- bM e1
    case e0' of
        Lam{} -> bM (EApp l e0' e1')
        _     -> pure (EApp l e0' e1')
bM e@(Var _ (Nm _ (U i) _)) = do
    st <- gets binds
    case IM.lookup i st of
        Just e' -> rE e'
        Nothing -> pure e
bM (Let l (n, e') e) = do
    e'B <- bM e'
    eB <- bM e
    pure $ Let l (n, e'B) eB
bM (Tup l es) = Tup l <$> traverse bM es; bM (Arr l es) = Arr l <$> traverse bM es
bM (Anchor l es) = Anchor l <$> traverse bM es; bM (OptionVal l es) = OptionVal l <$> traverse bM es
bM (Lam l n e) = Lam l n <$> bM e
bM (Implicit l e) = Implicit l <$> bM e;
bM (Guarded l e0 e1) = Guarded l <$> bM e0 <*> bM e1
bM (Cond l p e0 e1) = Cond l <$> bM p <*> bM e0 <*> bM e1
bM e@Column{} = pure e; bM e@IParseCol{} = pure e; bM e@FParseCol{} = pure e; bM e@AllField{} = pure e
bM e@LastField{} = pure e; bM e@Field{} = pure e; bM e@ParseCol{} = pure e; bM e@AllColumn{} = pure e; bM e@RegexCompiled{} = pure e
bM e@IntLit{} = pure e; bM e@FloatLit{} = pure e; bM e@StrLit{} = pure e; bM e@RegexLit{} = pure e; bM e@BoolLit{} = pure e
bM e@BB{} = pure e; bM e@NB{} = pure e; bM e@UB{} = pure e; bM e@TB{} = pure e
bM ResVar{} = desugar; bM Dfn{} = desugar; bM Paren{} = desugar

iE :: E (T K) -> RM (T K) (E (T K))
iE e@NB{} = pure e; iE e@UB{} = pure e; iE e@BB{} = pure e; iE e@TB{} = pure e
iE e@Column{} = pure e; iE e@ParseCol{} = pure e; iE e@IParseCol{} = pure e; iE e@FParseCol{} = pure e
iE e@Field{} = pure e; iE e@LastField{} = pure e; iE e@AllField{} = pure e; iE e@AllColumn{} = pure e
iE e@IntLit{} = pure e; iE e@FloatLit{} = pure e; iE e@BoolLit{} = pure e; iE e@StrLit{} = pure e
iE e@RegexLit{} = pure e; iE e@RegexCompiled{} = pure e
iE (EApp t e e') = EApp t <$> iE e <*> iE e'
iE (Guarded t p e) = Guarded t <$> iE p <*> iE e
iE (Implicit t e) = Implicit t <$> iE e
iE (Lam t n e) = Lam t n <$> iE e
iE (Tup t es) = Tup t <$> traverse iE es
iE (Arr t es) = Arr t <$> traverse iE es
iE (Anchor t es) = Anchor t <$> traverse iE es
iE (OptionVal t es) = OptionVal t <$> traverse iE es
iE (Cond t p e e') = Cond t <$> iE p <*> iE e <*> iE e'
iE (Let _ (n, e') e) = do
    eI <- iE e'
    modify (bind n eI) *> iE e
iE e@(Var t (Nm _ (U i) _)) = do
    st <- gets binds
    case IM.lookup i st of
        Just e' -> do {er <- rE e'; pure $ fmap (aT (match (eLoc er) t)) er}
        Nothing -> pure e
iE Dfn{} = desugar; iE Paren{} = desugar; iE ResVar{} = desugar
