-----------------------------------------------------------------------------
-- |
-- Module      :  Language.Hamler.CodeGen
-- Copyright   :  (c) Feng Lee 2020
-- License     :  BSD-style (see the LICENSE file)
--
-- Maintainer  :  Feng Lee, feng@emqx.io
-- Stability   :  experimental
-- Portability :  portable
--
-- Generate CoreErlang IR from Purescript source code.
--
-----------------------------------------------------------------------------
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}
module Language.Hamler.CodeGen
  ( moduleToErl
  , runTranslate
  ) where

import           Control.Lens
import           Control.Monad.Except
import           Control.Monad.State
import           Control.Monad.Writer
import           Data.List                          as LL
import           Data.Map                           as M
import           Data.Text                          (Text, unpack)
import qualified Data.Text.Lazy                     as L
import           Debug.Trace
import           Language.CoreErlang                as E
import           Language.Hamler.Prelude
import qualified Language.PureScript.AST.Literals   as L
import           Language.PureScript.CoreFn         as C
import           Language.PureScript.CoreFn.Binders
import           Language.PureScript.Names
import           Language.PureScript.PSString
import           Prelude
import           Text.Pretty.Simple

type MError = String
type MLog = String

type Translate = ExceptT MError ( StateT GState ( Writer MLog ))

data GState = GState
  { _gsmoduleName   :: ModuleName
  , _ffiFun         :: M.Map Text (Int,E.Expr)
  , _globalVar      :: M.Map Text Int
  , _localVar       :: M.Map Text Int
  , _letMap         :: M.Map Text (Int,E.Expr)
  , _binderVarIndex :: Int
  } deriving (Show)

makeLenses ''GState

emptyGState = GState (ModuleName []) (M.fromList plist ) M.empty M.empty M.empty 0

runTranslate :: Translate a -> (((Either MError a),GState), MLog)
runTranslate translate = runWriter $ runStateT (runExceptT translate) emptyGState

-- | Purescript CoreFn to CoreErlang AST
moduleToErl :: C.Module C.Ann -> Translate E.Module
moduleToErl C.Module{..} = do --undefined
  modify (\x -> x & gsmoduleName .~ moduleName)
  funDecls <- concat <$>  mapM bindToErl moduleDecls
  gs <- get
  -- | exports
  exports <- forM moduleExports $ \ident -> do
    let name = showQualified runIdent $ mkQualified ident (gs ^. gsmoduleName)
    case M.lookup name (gs ^. globalVar) of
      Just args ->return $  FunName (Atom $ unpack name, toInteger args)
      Nothing -> case M.lookup name (gs ^. ffiFun) of
        Just (args,_) -> return $  FunName (Atom $ unpack name, toInteger args)
        Nothing -> error "error of export var!"
  return $ E.Module (Atom $ unpack $ runModuleName moduleName) exports [] funDecls

-- | Purescript Bind to CoreErlang FunDef
bindToErl :: C.Bind C.Ann -> Translate [FunDef]
bindToErl (NonRec _ ident e) = do -- undefined
  e' <- exprToErl e
  gs <- get
  let name = showQualified runIdent $ mkQualified ident (gs ^. gsmoduleName)
  -- | Handle the top bindings
  case e' of
    Lam vrs _ -> do
      modify (\x-> x & globalVar %~ M.insert name (length vrs) )
      return $ [FunDef (Constr $ FunName (Atom $ unpack name, toInteger
                                          $ length vrs)) (Constr e')]
    x -> do
      modify (\x-> x & globalVar %~ M.insert name 0)
      return $ [FunDef (Constr $ FunName (Atom $ unpack name, 0))
         (Constr $ Lam [] (Expr $ Constr $ e'))]
bindToErl (C.Rec xs) = do
  -- | 需要确定所有循环引用函数的名字和参数数量
  gs <- get
  let ns = fmap (\((_,a),b) -> (mkname gs a,getArgNum b)) xs
  modify (\x -> x & globalVar %~ mapInsertList ns)
  concat <$> mapM (\((_,a),b) -> bindToErl (NonRec undefined a b)) xs
  where expend s (Abs _ ident expr) = expend (ident:s) expr
        expend s exp                = (s,exp)
        -- | 这里可能出现参数数量错误问题
        getArgNum s = length $ fst $ expend [] s
        mkname gs ident = showQualified runIdent $ mkQualified ident (gs ^. gsmoduleName)

bindToLetFunDef :: C.Bind C.Ann -> Translate ()
bindToLetFunDef (NonRec _ ident e) = do -- undefined
  e' <- exprToErl e
  gs <- get
  let name = runIdent ident
  -- | 处理顶层绑定时的各种情况
  case e' of
    Lam vrs _ -> do
      modify (\x-> x & letMap %~ M.insert name (length vrs,e') )
    x -> do
      modify (\x-> x & letMap %~ M.insert name (0,
                   Lam [] (Expr $ Constr $ e')
                                               ))
bindToLetFunDef x = error $ L.unpack $ pShow x

-- | CoreFn Expr to CoreErlang Expr
exprToErl :: C.Expr C.Ann -> Translate E.Expr
exprToErl (Literal _ l) = literalToErl l
exprToErl (Constructor _ p c ids) = do
  let args = length ids
      -- | Tuple for constructor
      cvar i =  E.Var $ Constr ("_" <> show i)
      vars = fmap cvar [0..args-1]
      ckv i =  Expr $ Constr $ EVar $ cvar i
      cm = Tuple $ fmap ckv [0..args-1]
  return $ Lam vars (Expr $ Constr $ cm)
exprToErl (Accessor _ pps e) = do
  e' <- exprToErl e
  return $ ModCall (mapsAtom, getAtom) [ppsToAtomExprs pps, Expr $ Constr e']
exprToErl (ObjectUpdate _ e xs) = do
  e' <- exprToErl e
  let foldFun m (k,v) = do
        v' <- exprToErl v
        return $ ModCall (mapsAtom,putAtom)
          [ppsToAtomExprs k ,Expr $ Constr v',Expr $ Constr m]
  foldM foldFun e' xs
exprToErl t@(Abs _ i e) = do
  -- | 备份局部变量表，以备使用和恢复
  gs <- get

  let (xs,e') = expend [] t
      xs' = runIdent <$> reverse xs
      allVar = M.size (gs ^. localVar)
      iks = zip  xs' [allVar..]
      vars = fmap (\(_,i) -> E.Var $ Constr ("_" <> show i)) iks

  -- | 将变量列表iks插入局部变量表，如果有同名的插入操作会覆盖掉原变量，
  -- 这样在这个表达式中实现局部作用域
  modify (\x -> x & localVar %~ mapInsertList iks)
  -- | 计算表达式
  e'' <- exprToErl e'
  case e'' of
    Lam cv ce -> do
      put gs
      return $ Lam (vars <> cv)  ce
    _ -> do
      -- | 恢复局部变量表
      put gs
      -- | 返回结果
      return $ Lam vars (Expr $ Constr e'')
  where expend s (Abs _ ident expr) = expend (ident:s) expr
        expend s exp                = (s,exp)
exprToErl t@(C.App _ _ _) = do
  let (e',xs) = expend t []
  e'' <- exprToErl e'
  xs' <- mapM exprToErl xs
-- | 解决下面的问题
--g x y = k
--  where k x a b c d y = y
--t = (g 1 2) 1 2 3 4 5 6
-- 确定参数的数量再处理
  case e'' of
    (E.Fun (E.FunName (Atom name,args))) -> do
      case args == (fromIntegral $  length xs') of  -- 参数等于需要的时候
        True ->return $  E.App (Expr $ Constr e'') (fmap (Expr . Constr) xs')
        False -> if (fromIntegral $ length xs') > args
          then  do  -- 参数多于需要的时候
          let (xs1,xs2) = Prelude.splitAt (fromIntegral args) xs'
          return $ E.App (Expr $ Constr $ E.App (Expr $ Constr e'') $ fmap (Expr . Constr) xs1)
                     (fmap (Expr . Constr) xs2)
          else do  -- 参数少于需要的时候
          gs <- get
          let detal = args - (fromIntegral $ length xs')
              allVar = M.size $ gs ^. localVar
              vars = fmap (\i -> E.Var $ Constr ("_" <> show i)) [allVar .. allVar + fromIntegral detal-1]
          return $ Lam vars $ Expr $ Constr $ E.App (Expr $ Constr e'')
                                                     ((fmap (Expr . Constr) xs') <> (fmap (Expr . Constr . EVar) vars))
    _ -> return $ E.App (Expr $ Constr e'') $ fmap (Expr . Constr) xs'
  where expend (C.App _ l r) s = expend l (r:s)
        expend e s             = (e ,s)
exprToErl (C.Var _  qi) = do
  let name = showQualified runIdent qi
  gs <- get
  case M.lookup name (gs ^. localVar) of
    Just i -> return $ E.EVar $ E.Var $  Constr $ "_" <> show i
    Nothing -> case M.lookup name (gs ^. letMap) of
      Just (0,e) -> return $ E.App (Expr $ Constr e) []
      Just (_,e) -> return e
      Nothing -> case M.lookup name (gs ^. globalVar) of
        Just a-> case a of
          0 -> return $ E.App (Expr $ Constr $ E.Fun
                             $ E.FunName (Atom (unpack name),0) ) []
          x -> return $ E.Fun $ E.FunName (Atom (unpack name), toInteger x)
        Nothing -> case M.lookup name (gs ^. ffiFun) of
          Just (0,e) -> undefined
          Just (_,e) -> return e
          Nothing    -> case qi of
            Qualified (Just mn) ident ->do
              let mn' =unpack $ runModuleName mn
              return $ Lam [E.Var $ Constr $ "_0", E.Var $ Constr $ "_1"]
                       (Expr $ Constr $ ModCall ( Expr $ Constr $ Lit  $ LAtom  $ Atom mn'
                                                , Expr $ Constr $ Lit $ LAtom $ Atom $ unpack name)
                        [ Expr $ Constr $ EVar $  E.Var $ Constr $ "_0"
                        , Expr $ Constr $ EVar $ E.Var $ Constr $ "_1"])
            Qualified Nothing ident -> error $ show gs ++ show qi
exprToErl (C.Let _ bs e) = do
  mapM bindToLetFunDef bs
  e' <- exprToErl e
  return e'
exprToErl (C.Case _ es alts) = do
  gs <- get
  es' <- mapM exprToErl es
  let allVars = M.size $ gs ^. localVar
  modify (\x -> x & binderVarIndex .~ allVars)
  alts' <- mapM altToErl alts
  put gs
  return $ E.Case (E.Exprs $ Constr $ fmap Constr es') alts'

-- | CoreFn Alt to CoreErlang Alt
altToErl :: CaseAlternative C.Ann -> Translate (E.Ann E.Alt)
altToErl (CaseAlternative bs res) = do
  pats <- mapM binderToPat bs
  let guard = Guard $ Expr $ Constr $ Lit $ LAtom $ Atom "true"
      Right expr = res
  case res of
    Right expr -> do
      expr' <- exprToErl expr
      return $ Constr $ E.Alt (Pats $ Constr $ fmap Constr $ pats)
                          guard
                          (Expr $ Constr $ expr')
    Left xs -> do
      xs' <- guardToErl xs
      return $ Constr $ E.Alt (Pats $ Constr $ fmap Constr $ pats)
                          guard
                          (Exprs $ Constr [xs'])

guardToErl :: [(C.Guard C.Ann , C.Expr C.Ann)] -> Translate (E.Ann E.Expr)
guardToErl [] = do
  return $ Constr $ Lit $ LNil
guardToErl ((g,e):xs) = do
  g' <- exprToErl g
  e' <- exprToErl e
  xs' <- guardToErl xs
  let true = Pat $ Constr $ PLit $ LAtom $ Atom "true"
      false = Pat $ Constr $ PLit $ LAtom $ Atom "false"
      guard = Guard $ Expr $ Constr $ Lit $ LAtom $ Atom "true"
      altTrue = E.Alt true guard (Expr $ Constr e')
      altFalse = E.Alt false guard $ Expr xs'
  return $ Constr $ E.Case (E.Expr $ Constr $ g') [Constr altTrue,Constr altFalse]

mapInsertList :: Ord k => [(k,v)] -> M.Map k v -> M.Map k v
mapInsertList xs m0 = LL.foldl' (\m (k,v) -> M.insert k v m ) m0 xs

decodePPS = decodeStringWithReplacement

-- | CoreFn Literal to CoreErlang Expr
literalToErl :: L.Literal (C.Expr C.Ann) -> Translate E.Expr
literalToErl (NumericLiteral (Left i))  = return $ Lit $ LInt i
literalToErl (NumericLiteral (Right i)) = return $ Lit $ LFloat i
literalToErl (StringLiteral s)          = return $ Lit $ LString $ decodePPS s
literalToErl (CharLiteral c)            = return $ Lit $ LChar c
literalToErl (BooleanLiteral True)      = return $ Lit $ LAtom (Atom "true")
literalToErl (BooleanLiteral False)     = return $ Lit $ LAtom (Atom "false")
literalToErl (ArrayLiteral xs)          = do
  xs' <- mapM exprToErl xs
  return $ E.List (L $ fmap (Expr . Constr) xs')
literalToErl (ObjectLiteral xs)         = do
  xs' <- forM xs $ \(pps,e) -> do
    e' <- exprToErl e
    return ( ppsToAtomExprs pps
           , Expr $ Constr e')
  return $ EMap $ E.Map xs'

-- | Binder to Pat
binderToPat :: Binder C.Ann -> Translate Pat
binderToPat (NullBinder _)  =do
  gs <- get
  let i = gs ^. binderVarIndex
  modify (\x -> x & binderVarIndex %~ (+1))
  return $ PVar $ E.Var $ Constr $ "_" <> show i
binderToPat (LiteralBinder _ l) = literalBinderToPat l
binderToPat (VarBinder _ i) = do
  gs <- get
  let index = gs ^. binderVarIndex
  modify (\x -> x & localVar  %~ M.insert (runIdent i) index)
  modify (\x -> x & binderVarIndex %~ (+1))
  return $ PVar $ E.Var $ Constr $ ("_" <> show index)
binderToPat (ConstructorBinder _ _ qi bs) = do
  bs' <-  mapM (binderToPat) bs
  return $ PTuple $  fmap (\(i,v) ->(v)) $ zip [0..] bs'
binderToPat (NamedBinder _ i b) = do
  gs <- get
  let index = gs ^. binderVarIndex
  modify (\x -> x & localVar  %~ M.insert (runIdent i) index)
  modify (\x -> x & binderVarIndex %~ (+1))
  binderToPat b

-- | Literal Binder to Pat
literalBinderToPat :: L.Literal (C.Binder C.Ann) -> Translate E.Pat
literalBinderToPat (NumericLiteral (Left i))  = return $ PLit $ LInt i
literalBinderToPat (NumericLiteral (Right i)) = return $ PLit $ LFloat i
literalBinderToPat (StringLiteral s)          = return $ PLit $ LString $ decodePPS s
literalBinderToPat (CharLiteral c)            = return $ PLit $ LChar c
literalBinderToPat (BooleanLiteral True)      = return $ PLit $ LAtom (Atom "true")
literalBinderToPat (BooleanLiteral False)     = return $ PLit $ LAtom (Atom "false")
literalBinderToPat (ArrayLiteral xs)          = do
  xs' <- mapM binderToPat xs
  return $ E.PList (L xs')
literalBinderToPat (ObjectLiteral xs)         = do
  xs' <- forM xs $ \(pps,e) -> do
    e' <- binderToPat e
    return (KLit $ LAtom $ Atom $ decodePPS pps, e')
  return $ PMap $ E.Map xs'

ppsToAtomExprs :: PSString -> Exprs
ppsToAtomExprs pps = Expr $ Constr $ Lit $ LAtom $ Atom $ decodePPS pps

stringToAtomExprs :: String -> Exprs
stringToAtomExprs s = Expr $ Constr $ Lit $ LAtom $ Atom s

mapsAtom :: Exprs
mapsAtom = stringToAtomExprs "maps"

getAtom :: Exprs
getAtom = stringToAtomExprs "get"

putAtom :: Exprs
putAtom = stringToAtomExprs "put"

