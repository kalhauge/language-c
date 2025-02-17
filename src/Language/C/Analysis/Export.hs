-----------------------------------------------------------------------------

-----------------------------------------------------------------------------

{- |
Module      :  Language.C.Analysis.Export
Copyright   :  (c) 2008 Benedikt Huber
License     :  BSD-style
Maintainer  :  benedikt.huber@gmail.com
Stability   :  prototype
Portability :  ghc

/WARNING/ : This is just an implementation sketch and not very well tested.

Export 'SemRep' entities to 'AST' nodes.
-}
module Language.C.Analysis.Export (
  exportDeclr,
  exportType,
  exportTypeDecl,
  exportTypeSpec,
  exportTypeDef,
  exportCompType,
  exportCompTypeDecl,
  exportCompTypeRef,
  exportEnumType,
  exportEnumTypeDecl,
  exportEnumTypeRef,
  export,
)
where

import Data.Functor ((<$>))
import Data.List
import qualified Data.Map as Map
import Data.Maybe
import Language.C.Analysis.SemRep
import Language.C.Data.Ident
import Language.C.Data.Name (nameId)
import Language.C.Data.Node
import Language.C.Syntax.AST

{- | Export global declarations
TODO: This does not export tags and type defs yet
-}
export :: GlobalDecls -> CTranslUnit
export (GlobalDecls objs tags typedefs) = CTranslUnit (declarations ++ []) undefNode
 where
  declarations = fmap exportIdentDecl (filterBuiltins $ Map.toList objs)
  filterBuiltins = Prelude.filter noBuiltIns
  noBuiltIns (idn, _) =
    let n = identToString idn
     in not ("__builtin" `isPrefixOf` n)
          && (n /= "__FUNCTION__")
          && (n /= "__PRETTY_FUNCTION__")
          && (n /= "__func__")

exportIdentDecl :: (Ident, IdentDecl) -> CExternalDeclaration NodeInfo
exportIdentDecl (_, Declaration decl) = CDeclExt $ exportDeclaration decl
exportIdentDecl (_, FunctionDef fundef) = CFDefExt $ exportFunDef fundef
exportIdentDecl (_, ObjectDef objdef) = CDeclExt $ exportObject objdef
exportIdentDecl (_, EnumeratorDef _) = error "not implemented: enumerator definition"

exportObject :: ObjDef -> CDeclaration NodeInfo
exportObject d@(ObjDef _ mInit nInf) = CDecl specs' [CDeclarationItem decl mInit Nothing] nInf
 where
  (DeclAttrs _ _ attrs) = declAttrs d
  specs = exportDeclarationSpecifiers (declAttrs d)
  (specs', decl) = exportDeclr specs (declType d) attrs (declName d)

exportDeclaration :: Decl -> CDeclaration NodeInfo
exportDeclaration d = CDecl specs' [CDeclI decl] undefNode
 where
  (DeclAttrs _ _ attrs) = declAttrs d
  specs = exportDeclarationSpecifiers (declAttrs d)
  (specs', decl) = exportDeclr specs (declType d) attrs (declName d)

exportFunDef :: FunDef -> CFunctionDef NodeInfo
exportFunDef d@(FunDef _ stmt _) = CFunDef cDeclSpecs cDecl oldStyleParams stmt undefNode
 where
  (cDeclSpecs, cDecl) = exportDeclr specs (declType d) ([] :: Attributes) (declName d)
  oldStyleParams = [] :: [CDeclaration NodeInfo] -- TODO:?
  specs = exportDeclarationSpecifiers (declAttrs d) :: [CDeclarationSpecifier NodeInfo]

exportDeclarationSpecifiers :: DeclAttrs -> [CDeclarationSpecifier NodeInfo]
exportDeclarationSpecifiers (DeclAttrs funcAttrs storage attrs) = specifiers
 where
  specifiers = (CFunSpec <$> exportFunAttrs funcAttrs) ++ (CStorageSpec <$> exportStorage storage)

{- | Export Declarator

  Synopsis: @exportDeclr other_specs type attributes variable-name@
-}
exportDeclr :: [CDeclSpec] -> Type -> Attributes -> VarName -> ([CDeclSpec], CDeclr)
exportDeclr other_specs ty attrs name =
  (other_specs ++ specs, CDeclr ident derived asmname (exportAttrs attrs) ni)
 where
  (specs, derived) = exportType ty
  (ident, asmname) = case name of
    (VarName vident asmname_opt) -> (Just vident, asmname_opt)
    _ -> (Nothing, Nothing)

exportTypeDecl :: Type -> CDecl
exportTypeDecl ty =
  CDecl declspecs declrs ni
 where
  (declspecs, derived) = exportType ty
  declrs
    | null derived = []
    | otherwise = [CDeclI $ CDeclr Nothing derived Nothing [] ni]

exportTypeDef :: TypeDef -> CDecl
exportTypeDef (TypeDef ident ty attrs node_info) =
  CDecl (CStorageSpec (CTypedef ni) : declspecs) [declr] node_info
 where
  (declspecs, derived) = exportType ty
  declr = CDeclI $ CDeclr (Just ident) derived Nothing (exportAttrs attrs) ni

-- | Export a type to syntax
exportType :: Type -> ([CDeclSpec], [CDerivedDeclr])
exportType ty = exportTy [] ty
 where
  exportTy dd (PtrType ity tyquals attrs) =
    let ptr_declr = CPtrDeclr (exportTypeQualsAttrs tyquals attrs) ni
     in exportTy (ptr_declr : dd) ity
  exportTy dd (ArrayType ity array_sz tyquals attrs) =
    let arr_declr = CArrDeclr (exportTypeQualsAttrs tyquals attrs) (exportArraySize array_sz) ni
     in exportTy (arr_declr : dd) ity
  exportTy dd (FunctionType (FunType ity params variadic) attrs) =
    let fun_declr = CFunDeclr (CFunParamsNew (map exportParamDecl params) variadic) (exportAttrs attrs) ni
     in exportTy (fun_declr : dd) ity
  exportTy dd (FunctionType (FunTypeIncomplete ity) attrs) =
    let fun_declr = CFunDeclr (CFunParamsNew [] False) (exportAttrs attrs) ni
     in exportTy (fun_declr : dd) ity
  exportTy dd (TypeDefType (TypeDefRef ty_ident _ node) quals attrs) =
    let declspecs =
          CTypeSpec (CTypeDef ty_ident node)
            : map CTypeQual (exportTypeQualsAttrs quals attrs)
     in (declspecs, reverse dd)
  exportTy dd (DirectType ity quals attrs) =
    let declspecs =
          map CTypeQual (exportTypeQualsAttrs quals attrs)
            ++ map CTypeSpec (exportTypeSpec ity)
     in (declspecs, reverse dd)

exportTypeQuals :: TypeQuals -> [CTypeQual]
exportTypeQuals quals = mapMaybe select [(constant, CConstQual ni), (volatile, CVolatQual ni), (restrict, CRestrQual ni)]
 where
  select (predicate, tyqual)
    | predicate quals = Just tyqual
    | otherwise = Nothing

exportTypeQualsAttrs :: TypeQuals -> Attributes -> [CTypeQual]
exportTypeQualsAttrs tyqs attrs = (exportTypeQuals tyqs ++ map CAttrQual (exportAttrs attrs))

exportArraySize :: ArraySize -> CArrSize
exportArraySize (ArraySize static e) = CArrSize static e
exportArraySize (UnknownArraySize complete) = CNoArrSize complete

exportTypeSpec :: TypeName -> [CTypeSpec]
exportTypeSpec tyname =
  case tyname of
    TyVoid -> [CVoidType ni]
    TyIntegral ity -> exportIntType ity
    TyFloating fty -> exportFloatType fty
    TyComplex fty -> exportComplexType fty
    TyComp comp -> exportCompTypeDecl comp
    TyEnum enum -> exportEnumTypeDecl enum
    TyBuiltin TyVaList -> [CTypeDef (internalIdent "va_list") ni]
    TyBuiltin TyAny -> [CTypeDef (internalIdent "__ty_any") ni]

exportIntType :: IntType -> [CTypeSpec]
exportIntType ty =
  case ty of
    TyBool -> [CBoolType ni]
    TyChar -> [CCharType ni]
    TySChar -> [CSignedType ni, CCharType ni]
    TyUChar -> [CUnsigType ni, CCharType ni]
    TyShort -> [CShortType ni]
    TyUShort -> [CUnsigType ni, CShortType ni]
    TyInt -> [CIntType ni]
    TyUInt -> [CUnsigType ni, CIntType ni]
    TyInt128 -> [CInt128Type ni]
    TyUInt128 -> [CUnsigType ni, CInt128Type ni]
    TyLong -> [CLongType ni]
    TyULong -> [CUnsigType ni, CLongType ni]
    TyLLong -> [CLongType ni, CLongType ni]
    TyULLong -> [CUnsigType ni, CLongType ni, CLongType ni]

exportFloatType :: FloatType -> [CTypeSpec]
exportFloatType ty =
  case ty of
    TyFloat -> [CFloatType ni]
    TyDouble -> [CDoubleType ni]
    TyLDouble -> [CLongType ni, CDoubleType ni]
    TyFloatN n x -> [CFloatNType n x ni]

exportComplexType :: FloatType -> [CTypeSpec]
exportComplexType ty = (CComplexType ni) : exportFloatType ty

exportCompTypeDecl :: CompTypeRef -> [CTypeSpec]
exportCompTypeDecl ty = [CSUType (exportComp ty) ni]
 where
  exportComp (CompTypeRef sue_ref comp_tag _n) =
    CStruct
      (if comp_tag == StructTag then CStructTag else CUnionTag)
      (exportSUERef sue_ref)
      Nothing
      []
      ni

exportEnumTypeDecl :: EnumTypeRef -> [CTypeSpec]
exportEnumTypeDecl ty = [CEnumType (exportEnum ty) ni]
 where
  exportEnum (EnumTypeRef sue_ref _n) =
    CEnum (exportSUERef sue_ref) Nothing [] ni

exportCompType :: CompType -> [CTypeSpec]
exportCompType (CompType sue_ref comp_tag members attrs node_info) = [CSUType comp ni]
 where
  comp =
    CStruct
      (if comp_tag == StructTag then CStructTag else CUnionTag)
      (exportSUERef sue_ref)
      (Just (map exportMemberDecl members))
      (exportAttrs attrs)
      node_info
exportCompTypeRef :: CompType -> [CTypeSpec]
exportCompTypeRef (CompType sue_ref com_tag _ _ node_info) = exportCompTypeDecl (CompTypeRef sue_ref com_tag node_info)

exportEnumType :: EnumType -> [CTypeSpec]
exportEnumType (EnumType sue_ref enumerators attrs node_info) = [CEnumType enum ni]
 where
  enum =
    CEnum
      (exportSUERef sue_ref)
      (Just (map exportEnumerator enumerators))
      (exportAttrs attrs)
      node_info
  exportEnumerator (Enumerator ident val _ty _) = CEnumVar ident (Just val)

exportEnumTypeRef :: EnumType -> [CTypeSpec]
exportEnumTypeRef (EnumType sue_ref _ _ node_info) = exportEnumTypeDecl (EnumTypeRef sue_ref node_info)

-- XXX: relies on a the source program not having any $'s in it
exportSUERef :: SUERef -> Maybe Ident
exportSUERef (AnonymousRef name) = Just (internalIdent $ "$" ++ show (nameId name))
exportSUERef (NamedRef ident) = Just ident

exportMemberDecl :: MemberDecl -> CDecl
exportMemberDecl (AnonBitField ty expr node_info) =
  CDecl (map CTypeSpec $ exportTypeSpec $ fromDirectType ty) [CDeclarationExpr expr] node_info
exportMemberDecl (MemberDecl vardecl bitfieldsz node_info) =
  let (specs, declarator) = exportVarDecl vardecl
   in CDecl specs [CDeclarationItem declarator Nothing bitfieldsz] node_info
exportVarDecl :: VarDecl -> ([CDeclSpec], CDeclr)
-- NOTE: that there is an ambiguity between two possible places for __attributes__ s here
exportVarDecl (VarDecl name attrs ty) = exportDeclr (exportDeclAttrs attrs) ty [] name
exportParamDecl :: ParamDecl -> CDecl
exportParamDecl paramdecl =
  let (specs, declr) = exportVarDecl (getVarDecl paramdecl)
   in CDecl specs [CDeclarationItem declr Nothing Nothing] (nodeInfo paramdecl)

exportDeclAttrs :: DeclAttrs -> [CDeclSpec]
exportDeclAttrs (DeclAttrs fun_attrs storage attrs) =
  map CFunSpec (exportFunAttrs fun_attrs)
    ++ map CStorageSpec (exportStorage storage)
    ++ map (CTypeQual . CAttrQual) (exportAttrs attrs)

-- | export function attributes to C function specifiers
exportFunAttrs :: FunctionAttrs -> [CFunSpec]
exportFunAttrs fattrs = catMaybes [inlQual, noretQual]
 where
  inlQual = if isInline fattrs then Just (CInlineQual ni) else Nothing
  noretQual = if isNoreturn fattrs then Just (CNoreturnQual ni) else Nothing

{- | express storage in terms of storage specifiers.

This isn't always possible and depends on the context the identifier is declared.
Most importantly, if there is a /conflicting/ declaration in scope, export is impossible.
Furthermore, automatic storage is impossible in file scope.
If the storage can actually be specified, the export is correct.
-}
exportStorage :: Storage -> [CStorageSpec]
exportStorage NoStorage = []
exportStorage (Auto reg) = if reg then [CRegister ni] else []
exportStorage (Static InternalLinkage thread_local) = threadLocal thread_local [CStatic ni]
exportStorage (Static ExternalLinkage thread_local) = threadLocal thread_local [CExtern ni]
exportStorage (Static NoLinkage _) = error "impossible storage: static without linkage"
exportStorage (FunLinkage InternalLinkage) = [CStatic ni]
exportStorage (FunLinkage ExternalLinkage) = []
exportStorage (FunLinkage NoLinkage) = error "impossible storage: function without linkage"

threadLocal :: Bool -> [CStorageSpec] -> [CStorageSpec]
threadLocal False = id
threadLocal True = ((CThread ni) :)

exportAttrs :: [Attr] -> [CAttr]
exportAttrs = map exportAttr
 where
  exportAttr (Attr ident es n) = CAttr ident es n

fromDirectType :: Type -> TypeName
fromDirectType (DirectType ty _ _) = ty
fromDirectType (TypeDefType (TypeDefRef _ ty _) _ _) = fromDirectType ty
fromDirectType _ = error "fromDirectType"

ni :: NodeInfo
ni = undefNode
