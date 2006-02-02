/* Copyright (C) 2003, 2004, 2006  Matthijs van Duin <xmath@cpan.org>
 *
 * Parts from perl, which is Copyright (C) 1991-2006 Larry Wall and others
 *
 * You may distribute under the same terms as perl itself, which is either 
 * the GNU General Public License or the Artistic License.
 */

#define PERL_CORE
#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#ifdef avhv_keys
#define SUPPORT_AVHV 1
#endif

#ifndef PERL_COMBI_VERSION
#define PERL_COMBI_VERSION (PERL_REVISION * 1000000 + PERL_VERSION * 1000 + \
				PERL_SUBVERSION)
#endif

#if (PERL_COMBI_VERSION >= 5009003)
#define PL_no_helem PL_no_helem_sv
#endif

#ifndef SvPVX_const
#define SvPVX_const SvPVX
#endif

#if (PERL_COMBI_VERSION >= 5009002)
#define PERL59CALLS 1
#endif

#ifdef USE_5005THREADS
#error "5.005 threads not supported by Data::Alias"
#endif

#define DA_AELEM 1
#define DA_HELEM 2
#define DA_PADSV 3
#define DA_RVSV  4
#define DA_GV    5
#define DA_AVHV  6

#define OPpOUTERPAD 2
#define OPpALIASAV  2
#define OPpALIASHV  4
#define OPpALIAS (OPpALIASAV | OPpALIASHV)

#define MOD(op) mod((op), OP_GREPSTART)

#define DA_TIED_ERR "Can't %s alias %s tied %s"
#define DA_ODD_HASH_ERR "Odd number of elements in hash assignment"
#define DA_TARGET_ERR "Unsupported alias target at %s line %"UVuf"\n"
#define DA_DEREF_ERR "Can't deref string (\"%.32s\")"

#define DA_TARGET(sv) ((SvTYPE(sv) == SVt_PVLV && LvTYPE(sv) == '~'))

STATIC OP *(*da_old_ck_rv2cv)(pTHX_ OP *op);
STATIC OP *(*da_old_ck_entersub)(pTHX_ OP *op);

#ifdef USE_ITHREADS

#define DA_GLOBAL_KEY "Data::Alias::_global"
#define DA_FETCH(create) hv_fetch(PL_modglobal, DA_GLOBAL_KEY, \
					sizeof(DA_GLOBAL_KEY) - 1, create)
#define DA_ACTIVE ((_dap = DA_FETCH(FALSE)) && (_da = *_dap))
#define DA_INIT (_da = *(_dap = DA_FETCH(TRUE)), \
		SvUPGRADE(_da, SVt_PVLV), LvTYPE(_da) = 't')

#define dDA SV *_da, **_dap
#define dDAforce SV *_da = *DA_FETCH(FALSE)

#define da_peeps (*(I32 *) &SvCUR(_da))
#define da_inside (*(I32 *) &SvIVX(_da))
#define da_iscope (*(PERL_CONTEXT **) &SvPVX(_da))
#define da_old_peepp (*(void (**)(pTHX_ OP *)) &LvTARG(_da))
#define da_cv (*(CV **) &LvTARGOFF(_da))
#define da_cvc (*(CV **) &LvTARGLEN(_da))

#else

#define dDA dNOOP
#define dDAforce dNOOP
#define DA_ACTIVE 42
#define DA_INIT

STATIC CV *da_cv, *da_cvc;
STATIC I32 da_peeps;
STATIC I32 da_inside;
STATIC PERL_CONTEXT *da_iscope;
STATIC void (*da_old_peepp)(pTHX_ OP *);

#endif

STATIC OP *da_tag_rv2cv(pTHX) { return NORMAL; }
STATIC OP *da_tag_list(pTHX) { return NORMAL; }
STATIC OP *da_tag_entersub(pTHX) { return NORMAL; }

STATIC void da_peep(pTHX_ OP *o);
STATIC int da_peep2(pTHX_ OP *o);

STATIC SV *da_target_ex(pTHX_ int type, SV *targ, MEM_SIZE arg) {
	SV *sv;
	if (targ && SvTEMP(targ) && SvREFCNT(targ) == 1)
		Perl_warn(aTHX_ "Useless modification of temporary variable");
	sv = sv_newmortal();
	sv_upgrade(sv, SVt_PVLV);
	LvTYPE(sv) = '~';
	LvTARG(sv) = SvREFCNT_inc(targ);
	LvTARGOFF(sv) = arg;
	LvTARGLEN(sv) = type;
	SvREADONLY_on(sv);
	return sv;
}

STATIC SV *da_target_aelem(pTHX_ AV *av, I32 index) {
	return da_target_ex(aTHX_ DA_AELEM, (SV *) av, index);
}

STATIC SV *da_target_helem(pTHX_ HV *hv, SV *key) {
	SV *sv = da_target_ex(aTHX_ DA_HELEM, (SV *) hv, 0);
	SvREADONLY_off(sv);
	sv_copypv(sv, key);
	SvREADONLY_on(sv);
	return sv;
}

STATIC SV *da_target_padsv(pTHX_ I32 padoffset) {
	return da_target_ex(aTHX_ DA_PADSV, (SV *) PL_comppad, padoffset);
}

STATIC SV *da_target_rvsv(pTHX_ SV *rv) {
	return da_target_ex(aTHX_ DA_RVSV, rv, 0);
}

STATIC SV *da_target_gv(pTHX_ GV *gv) {
	return da_target_ex(aTHX_ DA_GV, (SV *) gv, 0);
}

#if SUPPORT_AVHV
STATIC SV *da_target_avhv(pTHX_ SV *sv) {
	return da_target_ex(aTHX_ DA_AVHV, sv, 0);
}
#endif

STATIC PADOFFSET find_outerlex(pTHX_ CV **cvp, const char *name) {
	CV *cv = *cvp;
	U32 seq;
	PADOFFSET fake = 0, i;
	AV *av;
	SV **svp;

 again:	seq = CvOUTSIDE_SEQ(cv);
	*cvp = cv = CvOUTSIDE(cv);
	if (!cv || !CvDEPTH(cv))
		return 0;

	av = (AV *) *AvARRAY(CvPADLIST(cv));
	svp = AvARRAY(av);
	for (i = AvFILLp(av); i; i--) {
		SV *sv = svp[i];
		if (!sv || !SvPOK(sv) || !strEQ(SvPVX(sv), name))
			continue;
		if (SvFAKE(sv))
			fake = i;
		else if (seq > U_32(SvNVX(sv)) && seq <= (U32) SvIVX(sv))
			return i;
	}

	if (!fake)
		goto again;

	return fake;
}

STATIC SV *da_fetch(pTHX_ SV *sv) {
	if (!DA_TARGET(sv))
		goto bogus;
	switch (LvTARGLEN(sv)) {
	case DA_AELEM:
	case DA_PADSV: {
		SV **svp = av_fetch((AV *) LvTARG(sv), LvTARGOFF(sv), FALSE);
		return svp ? *svp : &PL_sv_undef;
	} case DA_HELEM: {
		HE *he = hv_fetch_ent((HV *) LvTARG(sv), sv, FALSE, 0);
		return he ? HeVAL(he) : &PL_sv_undef;
	} case DA_RVSV:
		sv = LvTARG(sv);
		if (SvTYPE(sv) == SVt_PVGV)
			return GvSV(sv);
		if (!SvROK(sv) || !(sv = SvRV(sv))
			|| (SvTYPE(sv) > SVt_PVLV && SvTYPE(sv) != SVt_PVGV))
			Perl_croak(aTHX_ "Not a SCALAR reference");
		return sv;
	case DA_GV:
		return LvTARG(sv);
	default:
	bogus:	Perl_croak(aTHX_ "Bizarre lvalue in da_fetch");
	}
}

STATIC void da_alias(pTHX_ SV *sv, SV *value) {
	if (!DA_TARGET(sv))
		goto bogus;
	SvTEMP_off(value);
	switch (LvTARGLEN(sv)) {
	case DA_AELEM:
		SvREFCNT_inc(value);
		if (!av_store((AV *) LvTARG(sv), LvTARGOFF(sv), value))
			SvREFCNT_dec(value);
		break;
	case DA_HELEM:
		SvREFCNT_inc(value);
		if (value == &PL_sv_undef)
			hv_delete_ent((HV *) LvTARG(sv), sv, G_DISCARD, 0);
		else if (!hv_store_ent((HV *) LvTARG(sv), sv, value, 0))
			SvREFCNT_dec(value);
		break;
	case DA_PADSV: {
		CV *cv = find_runcv(NULL);
		AV *av = (AV *) LvTARG(sv);
		PADOFFSET po = LvTARGOFF(sv);
		if (av != PL_comppad)
			Perl_croak(aTHX_ "Foreign pad variable");
		while (42) {
			av_store(av, po, SvREFCNT_inc(value));
			sv = AvARRAY(*AvARRAY(CvPADLIST(cv)))[po];
			if (!sv || !SvPOK(sv) || !SvFAKE(sv))
				break;
			po = find_outerlex(aTHX_ &cv, SvPVX(sv));
			if (!po)
				break;
			av = (AV *) AvARRAY(CvPADLIST(cv))[CvDEPTH(cv)];
		}
		break;
	} case DA_RVSV:
		if (SvTYPE(LvTARG(sv)) == SVt_PVGV)
			goto globassign;
		SvSetMagicSV(LvTARG(sv), sv_2mortal(newRV_inc(value)));
		break;
	case DA_GV: {
		SV **svp;
		GV *gv;
		if (!SvROK(value)) {
			SvSetMagicSV(LvTARG(sv), value);
			break;
		}
		value = SvRV(value);
	globassign:
		gv = (GV *) LvTARG(sv);
#ifdef GV_UNIQUE_CHECK
		if (GvUNIQUE(gv))
			Perl_croak(aTHX_ PL_no_modify);
#endif
		switch (SvTYPE(value)) {
			CV *cv;
		case SVt_PVCV:
			svp = (SV **) &GvCV(gv);
			cv = (CV *) *svp;
			if (cv == (CV *) value)
				break;
			if (GvCVGEN(gv)) {
				GvCV(gv) = NULL;
				GvCVGEN(gv) = 0;
				SvREFCNT_dec(cv);
			}
			PL_sub_generation++;
			break;
		case SVt_PVAV:	svp = (SV **) &GvAV(gv); break;
		case SVt_PVHV:	svp = (SV **) &GvHV(gv); break;
		case SVt_PVFM:	svp = (SV **) &GvFORM(gv); break;
		case SVt_PVIO:	svp = (SV **) &GvIOp(gv); break;
		default:	svp = &GvSV(gv);
		}
		GvMULTI_on(gv);
		if (GvINTRO(gv)) {
			GvINTRO_off(gv);
			SAVEGENERICSV(*svp);
			*svp = SvREFCNT_inc(value);
		} else {
			SV *old = *svp;
			*svp = SvREFCNT_inc(value);
			SvREFCNT_dec(old);
		}
		break;
	}
	default:
	bogus:	Perl_croak(aTHX_ "Bizarre lvalue in da_alias");
	}
}

STATIC OP *da_pp_anonlist(pTHX) {
	dSP; dMARK;
	I32 i = SP - MARK;
	AV *av = (AV *) sv_2mortal((SV *) newAV());
	SV **svp;
	av_extend(av, i - 1);
	AvFILLp(av) = i - 1;
	svp = AvARRAY(av);
	while (i--)
		SvTEMP_off(svp[i] = SvREFCNT_inc(POPs));
	PUSHs((SV *) av);
	RETURN;
}

STATIC OP *da_pp_anonhash(pTHX) {
	dSP; dMARK; dORIGMARK;
	HV *hv = (HV *) sv_2mortal((SV *) newHV());
	while (MARK < SP) {
		SV *key = *++MARK;
		SV *val = &PL_sv_undef;
		if (MARK < SP)
			SvTEMP_off(val = SvREFCNT_inc(*++MARK));
		else if (ckWARN(WARN_MISC))
			Perl_warner(aTHX_ packWARN(WARN_MISC),
				"Odd number of elements in anonymous hash");
		if (val == &PL_sv_undef)
			hv_delete_ent(hv, key, G_DISCARD, 0);
		else
			hv_store_ent(hv, key, val, 0);
	}
	SP = ORIGMARK;
	PUSHs((SV *) hv);
	RETURN;
}

STATIC OP *da_pp_aelemfast(pTHX) {
	dSP;
	AV *av = (PL_op->op_flags & OPf_SPECIAL) ?
			(AV *) PAD_SV(PL_op->op_targ) : GvAVn(cGVOP_gv);
	SV **svp = av_fetch(av, PL_op->op_private, TRUE);
	if (!svp || *svp == &PL_sv_undef)
		DIE(aTHX_ PL_no_aelem, PL_op->op_private);
	PUSHs(da_target_aelem(aTHX_ av, PL_op->op_private));
	RETURN;
}

STATIC OP *da_pp_aelem(pTHX) {
	dSP;
	SV *elem = POPs, **svp;
	AV *av = (AV *) POPs;
	IV index = SvIV(elem);
	if (SvRMAGICAL(av))
		DIE(aTHX_ DA_TIED_ERR, "put", "into", "array");
	if (SvROK(elem) && !SvGAMAGIC(elem) && ckWARN(WARN_MISC))
		Perl_warner(aTHX_ packWARN(WARN_MISC),
			"Use of reference \"%"SVf"\" as array index", elem);
	if (SvTYPE(av) != SVt_PVAV)
		RETPUSHUNDEF;
	if (!(svp = av_fetch(av, index, TRUE)))
		DIE(aTHX_ PL_no_aelem, index);
	if (PL_op->op_private & OPpLVAL_INTRO)
		save_aelem(av, index, svp);
	PUSHs(da_target_aelem(aTHX_ av, index));
	RETURN;
}

#if SUPPORT_AVHV
STATIC I32 da_avhv_index(pTHX_ AV *av, SV *key) {
	HV *keys = (HV *) SvRV(*AvARRAY(av));
	HE *he = hv_fetch_ent(keys, key, FALSE, 0);
	I32 index;
	if (!he)
		Perl_croak(aTHX_ "No such pseudo-hash field \"%s\"",
				SvPV_nolen(key));
	if ((index = SvIV(HeVAL(he))) <= 0)
		Perl_croak(aTHX_ "Bad index while coercing array into hash");
	if (index > AvMAX(av)) {
		I32 real = AvREAL(av);
		AvREAL_on(av);
		av_extend(av, index);
		if (!real)
			AvREAL_off(av);
	}
	return index;
}
#endif

STATIC OP *da_pp_helem(pTHX) {
	dSP;
	SV *key = POPs;
	HV *hv = (HV *) POPs;
	HE *he;
	if (SvRMAGICAL(hv))
		DIE(aTHX_ DA_TIED_ERR, "put", "into", "hash");
	if (SvTYPE(hv) != SVt_PVHV) {
#if SUPPORT_AVHV
		I32 i;
		if (SvTYPE(hv) != SVt_PVAV || !avhv_keys((AV *) hv))
			RETPUSHUNDEF;
		i = da_avhv_index(aTHX_ (AV *) hv, key);
		if (PL_op->op_private & OPpLVAL_INTRO)
			save_aelem((AV *) hv, i, &AvARRAY(hv)[i]);
		PUSHs(da_target_aelem(aTHX_ (AV *) hv, i));
#else
		PUSHs(&PL_sv_undef);
#endif
	} else {
		if (!(he = hv_fetch_ent(hv, key, TRUE, 0)))
			DIE(aTHX_ PL_no_helem, SvPV_nolen(key));
		if (PL_op->op_private & OPpLVAL_INTRO)
			save_helem(hv, key, &HeVAL(he));
		PUSHs(da_target_helem(aTHX_ hv, key));
	}
	RETURN;
}

STATIC OP *da_pp_aslice(pTHX) {
	dSP; dMARK;
	AV *av = (AV *) POPs;
	I32 max = -1, count, i;
	SV **svp = MARK;
	if (SvTYPE(av) != SVt_PVAV)
		DIE(aTHX_ "Not an array");
	if (SvRMAGICAL(av))
		DIE(aTHX_ DA_TIED_ERR, "put", "into", "array");
	count = AvFILLp(av) + 1;
	while (++svp <= SP) {
		i = SvIVx(*svp);
		if (i > max)
			max = i;
		else if (i < 0 && (i += count) < 0)
			DIE(aTHX_ PL_no_aelem, SvIVX(*svp));
		*svp = (SV *) i;
	}
	if (max > AvMAX(av))
		av_extend(av, max);
	if (!AvREAL(av) && AvREIFY(av))
		av_reify(av);
	svp = AvARRAY(av);
	AvFILLp(av) = max;
	while (++MARK <= SP) {
		i = (I32) *MARK;
		if (PL_op->op_private & OPpLVAL_INTRO)
			save_aelem(av, i, av_fetch(av, i, TRUE));
		*MARK = da_target_aelem(aTHX_ av, i);
	}
	RETURN;
}

STATIC OP *da_pp_hslice(pTHX) {
	dSP; dMARK;
	HV *hv = (HV *) POPs;
	SV *key;
	HE *he;
	if (SvRMAGICAL(hv))
		DIE(aTHX_ DA_TIED_ERR, "put", "into", "hash");
	if (SvTYPE(hv) != SVt_PVHV) {
#if SUPPORT_AVHV
		I32 i;
		if (SvTYPE(hv) != SVt_PVAV || !avhv_keys((AV *) hv)) {
			SP = MARK;
			RETURN;
		}
		while (++MARK <= SP) {
			i = da_avhv_index(aTHX_ (AV *) hv, key = *MARK);
			if (PL_op->op_private & OPpLVAL_INTRO)
				save_aelem((AV *) hv, i, &AvARRAY(hv)[i]);
			*MARK = da_target_aelem(aTHX_ (AV *) hv, i);
		}
#else
		SP = MARK;
#endif
	} else {
		while (++MARK <= SP) {
			if (!(he = hv_fetch_ent(hv, key = *MARK, TRUE, 0)))
				DIE(aTHX_ PL_no_helem, SvPV_nolen(key));
			if (PL_op->op_private & OPpLVAL_INTRO)
				save_helem(hv, key, &HeVAL(he));
			*MARK = da_target_helem(aTHX_ hv, key);
		}
	}
	RETURN;
}

STATIC OP *da_pp_padsv(pTHX) {
	dSP;
	if (PL_op->op_private & OPpLVAL_INTRO)
		SAVECLEARSV(PAD_SVl(PL_op->op_targ));
	if (PL_op->op_private & OPpOUTERPAD)
		XPUSHs(da_target_padsv(aTHX_ PL_op->op_targ));
	else
		XPUSHs(da_target_aelem(aTHX_ PL_comppad, PL_op->op_targ));
	RETURN;
}

STATIC OP *da_pp_gvsv(pTHX) {
	dSP;
	GV *gv = cGVOP_gv;
	if (PL_op->op_private & OPpLVAL_INTRO)
		save_scalar(gv);
	XPUSHs(da_target_rvsv(aTHX_ (SV *) gv));
	RETURN;
}

STATIC GV *fixglob(pTHX_ GV *gv) {
	SV **svp = hv_fetch(GvSTASH(gv), GvNAME(gv), GvNAMELEN(gv), FALSE);
	GV *egv;
	if (!svp || !(egv = (GV *) *svp) || GvGP(egv) != GvGP(gv))
		return gv;
	GvEGV(gv) = egv;
	return egv;
}

STATIC OP *da_pp_rv2sv(pTHX) {
	dSP; dTOPss;
	if (!SvROK(sv) && SvTYPE(sv) != SVt_PVGV) do {
		const char *tname;
		U32 type;
		switch (PL_op->op_type) {
		case OP_RV2AV:	type = SVt_PVAV; tname = "an ARRAY"; break;
		case OP_RV2HV:	type = SVt_PVHV; tname = "a HASH";   break;
		default:	type = SVt_PV;   tname = "a SCALAR";
		}
		if (SvGMAGICAL(sv)) {
			mg_get(sv);
			if (SvROK(sv))
				break;
		}
		if (!SvOK(sv))
			break;
		if (PL_op->op_private & HINT_STRICT_REFS)
			DIE(aTHX_ PL_no_symref, SvPV_nolen(sv), tname);
		sv = (SV *) gv_fetchpv(SvPV_nolen(sv), TRUE, type);
	} while (0);
	if (SvTYPE(sv) == SVt_PVGV)
		sv = (SV *) (GvEGV(sv) ? GvEGV(sv) : fixglob(aTHX_ (GV *) sv));
	if (PL_op->op_private & OPpLVAL_INTRO) {
		if (SvTYPE(sv) != SVt_PVGV || SvFAKE(sv))
			DIE(aTHX_ PL_no_localize_ref);
		switch (PL_op->op_type) {
		case OP_RV2AV: save_ary((GV *) sv);  break;
		case OP_RV2HV: save_hash((GV *) sv); break;
		default: save_scalar((GV *) sv);
		}
	}
	SETs(da_target_rvsv(aTHX_ sv));
	RETURN;
}

#if SUPPORT_AVHV
STATIC OP *da_pp_rv2hv(pTHX) {
	dSP;
	pp_rv2hv();
	if (SvTYPE(TOPs) == SVt_PVAV)
		SETs(da_target_avhv(aTHX_ TOPs));
	RETURN;
}
#endif

STATIC OP *da_pp_rv2gv(pTHX) {
	dSP; dTOPss;
	if (SvROK(sv)) {
	wasref:	sv = SvRV(sv);
		if (SvTYPE(sv) != SVt_PVGV)
			DIE(aTHX_ "Not a GLOB reference");
	} else if (SvTYPE(sv) != SVt_PVGV) {
		if (SvGMAGICAL(sv)) {
			mg_get(sv);
			if (SvROK(sv))
				goto wasref;
		}
		if (!SvOK(sv))
			DIE(aTHX_ PL_no_usym, "a symbol");
		if (PL_op->op_private & HINT_STRICT_REFS)
			DIE(aTHX_ PL_no_symref, SvPV_nolen(sv), "a symbol");
		sv = (SV *) gv_fetchpv(SvPV_nolen(sv), TRUE, SVt_PVGV);
	}
	if (SvTYPE(sv) == SVt_PVGV)
		sv = (SV *) (GvEGV(sv) ? GvEGV(sv) : fixglob(aTHX_ (GV *) sv));
	if (PL_op->op_private & OPpLVAL_INTRO)
		save_gp((GV *) sv, !(PL_op->op_flags & OPf_SPECIAL));
	SETs(da_target_gv(aTHX_ (GV *) sv));
	RETURN;
}

STATIC OP *da_pp_sassign(pTHX) {
	dSP; dPOPTOPssrl;
	if (PL_op->op_private & OPpASSIGN_BACKWARDS) {
		SV *temp = left; left = right; right = temp;
	}
	da_alias(aTHX_ right, left);
	SETs(left);
	RETURN;
}

STATIC OP *da_pp_aassign(pTHX) {
	dSP;
	SV **left, **llast, **right, **rlast;
	I32 gimme = GIMME_V;
	I32 done = FALSE;
	EXTEND(sp, 1);
	left  = POPMARK + PL_stack_base + 1;
	llast = SP;
	right = POPMARK + PL_stack_base + 1;
	rlast = left - 1;
	if (PL_op->op_private & OPpALIAS) {
		U32 hash = (PL_op->op_private & OPpALIASHV);
		U32 type = hash ? SVt_PVHV : SVt_PVAV;
		SV *sv = POPs;
		if (left != llast)
			DIE(aTHX_ "Panic: unexpected number of lvalues");
		PUTBACK;
		if (right != rlast || SvTYPE(*right) != type) {
			PUSHMARK(right - 1);
			hash ? da_pp_anonhash(aTHX) : da_pp_anonlist(aTHX);
			SPAGAIN;
		}
		da_alias(aTHX_ sv, TOPs);
		if (hash) {
			PL_op->op_type = OP_RV2HV;
			pp_rv2hv();
			PL_op->op_type = OP_AASSIGN;
			return NORMAL;
		}
		return pp_rv2av();
	}
	SP = right - 1;
	while (SP < rlast)
		if (!SvTEMP(*++SP))
			sv_2mortal(SvREFCNT_inc(*SP));
	SP = right - 1;
	while (left <= llast) {
		SV *sv = *left++;
		if (sv == &PL_sv_undef) {
			right++;
			continue;
		}
		switch (SvTYPE(sv)) {
		case SVt_PVAV: {
			SV **svp;
			if (SvRMAGICAL(sv))
				DIE(aTHX_ DA_TIED_ERR, "put", "into", "array");
			av_clear((AV *) sv);
			if (done || right > rlast)
				break;
			av_extend((AV *) sv, rlast - right);
			AvFILLp((AV *) sv) = rlast - right;
			svp = AvARRAY((AV *) sv);
			while (right <= rlast)
				SvTEMP_off(*svp++ = SvREFCNT_inc(*right++));
			break;
		} case SVt_PVHV: {
			SV *tmp, *val, **svp = rlast;
			U32 dups = 0, nils = 0;
			HE *he;
			if (SvRMAGICAL(sv))
				DIE(aTHX_ DA_TIED_ERR, "put", "into", "hash");
			hv_clear((HV *) sv);
			if (done || right > rlast)
				break;
			done = TRUE;
			hv_ksplit((HV *) sv, (rlast - right + 2) >> 1);
			if (1 & ~(rlast - right)) {
				if (ckWARN(WARN_MISC))
					Perl_warner(aTHX_ packWARN(WARN_MISC),
						DA_ODD_HASH_ERR);
				*++svp = &PL_sv_undef;
			}
			while (svp > right) {
				val = *svp--;  tmp = *svp--;
				he = hv_fetch_ent((HV *) sv, tmp, TRUE, 0);
				if (!he) /* is this possible? */
					DIE(aTHX_ PL_no_helem, SvPV_nolen(tmp));
				tmp = HeVAL(he);
				if (SvREFCNT(tmp) > 1) { /* existing element */
					svp[1] = svp[2] = NULL;
					dups += 2;
					continue;
				}
				if (val == &PL_sv_undef)
					nils++;
				SvREFCNT_dec(tmp);
				SvTEMP_off(HeVAL(he) = SvREFCNT_inc(val));
			}
			while (nils && (he = hv_iternext((HV *) sv))) {
				if (HeVAL(he) == &PL_sv_undef) {
					HeVAL(he) = &PL_sv_placeholder;
					HvPLACEHOLDERS(sv)++;
					nils--;
				}
			}
			if (gimme != G_ARRAY || !dups) {
				right = rlast - dups + 1;
				break;
			}
			while (svp++ < rlast) {
				if (*svp)
					*right++ = *svp;
			}
			break;
		}
#if SUPPORT_AVHV
		phash: {
			SV *key, *val, **svp = rlast, **he;
			U32 dups = 0;
			I32 i;
			if (SvRMAGICAL(sv))
				DIE(aTHX_ DA_TIED_ERR, "put", "into", "hash");
			avhv_keys((AV *) sv);
			av_fill((AV *) sv, 0);
			if (done || right > rlast)
				break;
			done = TRUE;
			if (1 & ~(rlast - right)) {
				if (ckWARN(WARN_MISC))
					Perl_warner(aTHX_ packWARN(WARN_MISC),
						DA_ODD_HASH_ERR);
				*++svp = &PL_sv_undef;
			}
			ENTER;
			while (svp > right) {
				val = *svp--;  key = *svp--;
				i = da_avhv_index(aTHX_ (AV *) sv, key);
				he = &AvARRAY(sv)[i];
				if (*he != &PL_sv_undef) {
					svp[1] = svp[2] = NULL;
					dups += 2;
					continue;
				}
				SvREFCNT_dec(*he);
				if (val == &PL_sv_undef) {
					SAVESPTR(*he);
					*he = NULL;
				} else {
					if (i > AvFILLp(sv))
						AvFILLp(sv) = i;
					SvTEMP_off(*he = SvREFCNT_inc(val));
				}
			}
			LEAVE;
			if (gimme != G_ARRAY || !dups) {
				right = rlast - dups + 1;
				break;
			}
			while (svp++ < rlast) {
				if (*svp)
					*right++ = *svp;
			}
			break;
		} default:
			if (DA_TARGET(sv) && LvTARGLEN(sv) == DA_AVHV) {
				sv = LvTARG(sv);
				goto phash;
			}
#else
		default:
#endif
			if (right > rlast)
				da_alias(aTHX_ sv, &PL_sv_undef);
			else if (done)
				da_alias(aTHX_ sv, *right = &PL_sv_undef);
			else
				da_alias(aTHX_ sv, *right);
			right++;
			break;
		}
	}
	if (gimme == G_ARRAY) {
		SP = right - 1;
		EXTEND(SP, 0);
		while (rlast < SP)
			*++rlast = &PL_sv_undef;
		RETURN;
	} else if (gimme == G_SCALAR) {
		dTARGET;
		XPUSHi(rlast - SP);
	}
	RETURN;
}

STATIC OP *da_pp_andassign(pTHX) {
	dSP;
	SV *sv = da_fetch(aTHX_ TOPs);
	if (SvTRUE(sv))
		return cLOGOP->op_other;
	TOPs = sv;
	return NORMAL;
}

STATIC OP *da_pp_orassign(pTHX) {
	dSP;
	SV *sv = da_fetch(aTHX_ TOPs);
	if (!SvTRUE(sv))
		return cLOGOP->op_other;
	TOPs = sv;
	return NORMAL;
}

STATIC OP *da_pp_push(pTHX) {
	dSP; dMARK; dORIGMARK; dTARGET;
	AV *av = (AV *) *++MARK;
	I32 i;
	if (SvRMAGICAL(av))
		DIE(aTHX_ DA_TIED_ERR, "push", "onto", "array");
	i = AvFILL(av);
	av_extend(av, i + (SP - MARK));
	while (MARK < SP)
		av_store(av, ++i, SvREFCNT_inc(*++MARK));
	SP = ORIGMARK;
	PUSHi(i + 1);
	RETURN;
}

STATIC OP *da_pp_unshift(pTHX) {
	dSP; dMARK; dORIGMARK; dTARGET;
	AV *av = (AV *) *++MARK;
	I32 i = 0;
	if (SvRMAGICAL(av))
		DIE(aTHX_ DA_TIED_ERR, "unshift", "onto", "array");
	av_unshift(av, SP - MARK);
	while (MARK < SP)
		av_store(av, i++, SvREFCNT_inc(*++MARK));
	SP = ORIGMARK;
	PUSHi(AvFILL(av) + 1);
	RETURN;
}

STATIC OP *da_pp_splice(pTHX) {
	dSP; dMARK; dORIGMARK;
	I32 ins = SP - MARK - 3;
	AV *av = (AV *) MARK[1];
	I32 off, del, count, i;
	SV **svp, *tmp;
	if (ins < 0) /* ?! */
		DIE(aTHX_ "Too few arguments for da_pp_splice");
	if (SvRMAGICAL(av))
		DIE(aTHX_ DA_TIED_ERR, "splice", "onto", "array");
	count = AvFILLp(av) + 1;
	off = SvIV(MARK[2]);
	if (off < 0 && (off += count) < 0)
		DIE(aTHX_ PL_no_aelem, off - count);
	del = SvIV(ORIGMARK[3]);
	if (del < 0 && (del += count - off) < 0)
		del = 0;
	if (off > count) {
		if (ckWARN(WARN_MISC))
			Perl_warner(aTHX_ packWARN(WARN_MISC),
				"splice() offset past end of array");
		off = count;
	}
	if ((count -= off + del) < 0) /* count of trailing elems */
		del += count, count = 0;
	i = off + ins + count - 1;
	if (i > AvMAX(av))
		av_extend(av, i);
	if (!AvREAL(av) && AvREIFY(av))
		av_reify(av);
	AvFILLp(av) = i;
	MARK = ORIGMARK + 4;
	svp = AvARRAY(av) + off;
	for (i = 0; i < ins; i++)
		SvTEMP_off(SvREFCNT_inc(MARK[i]));
	if (ins > del) {
		Move(svp+del, svp+ins, count, SV *);
		for (i = 0; i < del; i++)
			tmp = MARK[i], MARK[i-3] = svp[i], svp[i] = tmp;
		Copy(MARK+del, svp+del, ins-del, SV *);
	} else {
		for (i = 0; i < ins; i++)
			tmp = MARK[i], MARK[i-3] = svp[i], svp[i] = tmp;
		if (ins != del)
			Copy(svp+ins, MARK-3+ins, del-ins, SV *);
		Move(svp+del, svp+ins, count, SV *);
	}
	MARK -= 3;
	for (i = 0; i < del; i++)
		sv_2mortal(MARK[i]);
	SP = MARK + del - 1;
	RETURN;
}

STATIC OP *da_pp_leave(pTHX) {
	dSP;
	SV **newsp;
	PMOP *newpm;
	I32 gimme;
	PERL_CONTEXT *cx;
	SV *sv;

	if (PL_op->op_flags & OPf_SPECIAL)
		cxstack[cxstack_ix].blk_oldpm = PL_curpm;
	
	POPBLOCK(cx, newpm);

	gimme = OP_GIMME(PL_op, -1);
	if (gimme == -1) {
		if (cxstack_ix >= 0)
			gimme = cxstack[cxstack_ix].blk_gimme;
		else
			gimme = G_SCALAR;
	}

	if (gimme == G_SCALAR) {
		if (newsp == SP) {
			*++newsp = &PL_sv_undef;
		} else {
			sv = SvREFCNT_inc(TOPs);
			FREETMPS;
			*++newsp = sv_2mortal(sv);
		}
	} else if (gimme == G_ARRAY) {
		while (newsp < SP)
			if (!SvTEMP(sv = *++newsp))
				sv_2mortal(SvREFCNT_inc(sv));
	}
	PL_stack_sp = newsp;
	PL_curpm = newpm;
	LEAVE;
	return NORMAL;
}

STATIC OP *da_pp_return(pTHX) {
	dSP; dMARK;
	I32 cxix;
	PERL_CONTEXT *cx;
	bool clearerr = FALSE;
	I32 gimme;
	SV **newsp;
	PMOP *newpm;
	I32 optype = 0, type = 0;
	SV *sv = (MARK < SP) ? TOPs : &PL_sv_undef;
	OP *retop;

	cxix = cxstack_ix;
	while (cxix >= 0) {
		cx = &cxstack[cxix];
		type = CxTYPE(cx);
		if (type == CXt_EVAL || type == CXt_SUB || type == CXt_FORMAT)
			break;
		cxix--;
	}

#if PERL59CALLS
	if (cxix < 0) {
		if (CxMULTICALL(cxstack)) {	/* sort block */
			dounwind(0);
			*(PL_stack_sp = PL_stack_base + 1) = sv;
			return 0;
		}
		DIE(aTHX_ "Can't return outside a subroutine");
	}
#else
	if (PL_curstackinfo->si_type == PERLSI_SORT && cxix <= PL_sortcxix) {
		if (cxstack_ix > PL_sortcxix)
			dounwind(PL_sortcxix);
		*(PL_stack_sp = PL_stack_base + 1) = sv;
		return 0;
	}
	if (cxix < 0)
		DIE(aTHX_ "Can't return outside a subroutine");
#endif


	if (cxix < cxstack_ix)
		dounwind(cxix);

#if PERL59CALLS
	if (CxMULTICALL(&cxstack[cxix])) {
		gimme = cxstack[cxix].blk_gimme;
		if (gimme == G_VOID)
			PL_stack_sp = PL_stack_base;
		else if (gimme == G_SCALAR)
			*(PL_stack_sp = PL_stack_base + 1) = sv;
		return 0;
	}
#endif

	POPBLOCK(cx, newpm);
	switch (type) {
	case CXt_SUB:
#if PERL59CALLS
		retop = cx->blk_sub.retop;
#endif
		cxstack_ix++; /* temporarily protect top context */
		break;
	case CXt_EVAL:
		clearerr = !(PL_in_eval & EVAL_KEEPERR);
		POPEVAL(cx);
#if PERL59CALLS
		retop = cx->blk_eval.retop;
#endif
		if (CxTRYBLOCK(cx))
			break;
		lex_end();
		if (optype == OP_REQUIRE && !SvTRUE(sv)
				&& (gimme == G_SCALAR || MARK == SP)) {
			sv = cx->blk_eval.old_namesv;
			hv_delete(GvHVn(PL_incgv), SvPVX_const(sv), SvCUR(sv),
					G_DISCARD);
			DIE(aTHX_ "%"SVf" did not return a true value", sv);
		}
		break;
	case CXt_FORMAT:
		POPFORMAT(cx);
#if PERL59CALLS
		retop = cx->blk_sub.retop;
#endif
		break;
	default:
		DIE(aTHX_ "panic: return");
	}

	TAINT_NOT;
	if (gimme == G_SCALAR) {
		if (MARK == SP) {
			*++newsp = &PL_sv_undef;
		} else {
			sv = SvREFCNT_inc(TOPs);
			FREETMPS;
			*++newsp = sv_2mortal(sv);
		}
	} else if (gimme == G_ARRAY) {
		while (MARK < SP) {
			*++newsp = sv = *++MARK;
			if (!SvTEMP(sv) && !(SvREADONLY(sv) && SvIMMORTAL(sv)))
				sv_2mortal(SvREFCNT_inc(sv));
			TAINT_NOT;
		}
	}
	PL_stack_sp = newsp;
	LEAVE;
	if (type == CXt_SUB) {
		cxstack_ix--;
		POPSUB(cx, sv);
	} else {
		sv = Nullsv;
	}
	PL_curpm = newpm;
	LEAVESUB(sv);
	if (clearerr)
		sv_setpvn(ERRSV, "", 0);
#if (!PERL59CALLS)
	retop = pop_return();
#endif
	return retop;
}

STATIC OP *da_pp_leavesub(pTHX) {
	if (++PL_markstack_ptr == PL_markstack_max)
		markstack_grow();
	*PL_markstack_ptr = cxstack[cxstack_ix].blk_oldsp;
	return da_pp_return(aTHX);
}

STATIC OP *da_pp_entereval(pTHX) {
	dDAforce;
	PERL_CONTEXT *iscope = da_iscope;
	I32 inside = da_inside;
	I32 cxi = (cxstack_ix < cxstack_max) ? cxstack_ix + 1 : cxinc();
	void (*peepp)(pTHX_ OP *) = PL_peepp;
	OP *ret;
	da_iscope = &cxstack[cxi];
	da_inside = 1;
	if (peepp != da_peep) {
		da_old_peepp = peepp;
		PL_peepp = da_peep;
	}
	ret = pp_entereval();
	da_iscope = iscope;
	da_inside = inside;
	PL_peepp = peepp;
	return ret;
}

STATIC OP *da_pp_copy(pTHX) {
	dSP; dMARK;
	SV *sv;
	if (GIMME_V != G_ARRAY) {
		sv = (MARK < SP) ? TOPs : &PL_sv_undef;
		SP = MARK;
		XPUSHs(sv);
	}
	while (MARK < SP)
		if (!SvTEMP(sv = *++MARK) || SvREFCNT(sv) > 1)
			*MARK = sv_mortalcopy(sv);
	RETURN;
}

STATIC void da_lvalue(pTHX_ OP *op, int list) {
	switch (op->op_type) {
	case OP_PADSV: {
		SV **tmp = av_fetch(PL_comppad_name, op->op_targ, FALSE);
		if (tmp && SvPOK(*tmp) && SvFAKE(*tmp))
			op->op_private |= OPpOUTERPAD;
		op->op_ppaddr = da_pp_padsv;
		break;
	}
	case OP_AELEM:     op->op_ppaddr = da_pp_aelem;     break;
	case OP_AELEMFAST: op->op_ppaddr = da_pp_aelemfast; break;
	case OP_HELEM:     op->op_ppaddr = da_pp_helem;     break;
	case OP_ASLICE:    op->op_ppaddr = da_pp_aslice;    break;
	case OP_HSLICE:    op->op_ppaddr = da_pp_hslice;    break;
	case OP_GVSV:      op->op_ppaddr = da_pp_gvsv;      break;
	case OP_RV2SV:     op->op_ppaddr = da_pp_rv2sv;     break;
	case OP_RV2GV:     op->op_ppaddr = da_pp_rv2gv;     break;
	case OP_RV2HV:
		if (!list)
			goto bad;
#if SUPPORT_AVHV
		if (op->op_ppaddr != da_pp_rv2sv
				&& cUNOPx(op)->op_first->op_type != OP_GV)
			op->op_ppaddr = da_pp_rv2hv;
#endif
		break;
	case OP_LIST:
		if (!list)
			goto bad;
	case OP_NULL:
		op = (op->op_flags & OPf_KIDS) ? cUNOPx(op)->op_first : NULL;
		while (op) {
			da_lvalue(aTHX_ op, list);
			op = op->op_sibling;
		}
		break;
	case OP_COND_EXPR:
		op = cUNOPx(op)->op_first;
		while ((op = op->op_sibling))
			da_lvalue(aTHX_ op, list);
		break;
	case OP_SCOPE:
	case OP_LEAVE:
	case OP_LINESEQ:
		op = (op->op_flags & OPf_KIDS) ? cUNOPx(op)->op_first : NULL;
		while (op->op_sibling)
			op = op->op_sibling;
		da_lvalue(aTHX_ op, list);
		break;
	case OP_PUSHMARK:
	case OP_PADAV:
	case OP_PADHV:
	case OP_RV2AV:
		if (!list)
			goto bad;
		break;
	case OP_UNDEF:
		if (!list || (op->op_flags & OPf_KIDS))
			goto bad;
		break;
	default:
	bad:	qerror(Perl_mess(aTHX_ DA_TARGET_ERR, OutCopFILE(PL_curcop),
					(UV) CopLINE(PL_curcop)));
	}
}

STATIC void da_aassign(OP *op, OP *right) {
	OP *left, *la, *ra;
	int hash = FALSE, pad;

	/* make sure it fits the model exactly */
	if (!right || !(left = right->op_sibling) || left->op_sibling)
		return;
	if (left->op_type || !(left->op_flags & OPf_KIDS))
		return;
	if (!(left = cUNOPx(left)->op_first) || left->op_type != OP_PUSHMARK)
		return;
	if (!(la = left->op_sibling) || la->op_sibling)
		return;
	if (la->op_flags & OPf_PARENS)
		return;
	switch (la->op_type) {
	case OP_PADHV: hash = TRUE; case OP_PADAV: pad = TRUE;  break;
	case OP_RV2HV: hash = TRUE; case OP_RV2AV: pad = FALSE; break;
	default: return;
	}
	if (right->op_type || !(right->op_flags & OPf_KIDS))
		return;
	if (!(right = cUNOPx(right)->op_first) || right->op_type != OP_PUSHMARK)
		return;
	op->op_private = hash ? OPpALIASHV : OPpALIASAV;
	if (pad)
		la->op_type = OP_PADSV;
	else
		la->op_ppaddr = da_pp_rv2sv;
	if (!(ra = right->op_sibling) || ra->op_sibling)
		return;
	if (ra->op_flags & OPf_PARENS)
		return;
	if (hash) {
		if (ra->op_type != OP_PADHV && ra->op_type != OP_RV2HV)
			return;
	} else {
		if (ra->op_type != OP_PADAV && ra->op_type != OP_RV2AV)
			return;
	}
	ra->op_flags &= -2;
	ra->op_flags |= OPf_REF;
}

STATIC void da_transform(pTHX_ OP *op, int sib) {
	while (op) {
		OP *kid = Nullop, *tmp;
		int ksib = TRUE;
		OPCODE optype;

		if (op->op_flags & OPf_KIDS)
			kid = cUNOPx(op)->op_first;

		switch ((optype = op->op_type)) {
		case OP_NULL:
			optype = op->op_targ;
		default:
			switch (optype) {
			case OP_SETSTATE:
			case OP_NEXTSTATE:
			case OP_DBSTATE:
				PL_curcop = (COP *) op;
				break;
			case OP_LIST:
				if (op->op_ppaddr == da_tag_list) {
					if (da_peep2(aTHX_ op)) {
						dDAforce;
						PL_peepp = da_old_peepp;
					}
					return;
				}
				break;
			}
			break;
		case OP_LEAVE:
			if (op->op_ppaddr != da_tag_entersub)
				op->op_ppaddr = da_pp_leave;
			break;
		case OP_LEAVESUB:
		case OP_LEAVESUBLV:
		case OP_LEAVEEVAL:
		case OP_LEAVETRY:
			op->op_ppaddr = da_pp_leavesub;
			break;
		case OP_RETURN:
			op->op_ppaddr = da_pp_return;
			break;
		case OP_ENTEREVAL:
			op->op_ppaddr = da_pp_entereval;
			break;
		case OP_AASSIGN:
			op->op_ppaddr = da_pp_aassign;
			da_aassign(op, kid);
			MOD(kid);
			ksib = FALSE;
			da_lvalue(aTHX_ kid->op_sibling, TRUE);
			break;
		case OP_SASSIGN:
			op->op_ppaddr = da_pp_sassign;
			MOD(kid);
			ksib = FALSE;
			if (!(op->op_private & OPpASSIGN_BACKWARDS))
				da_lvalue(aTHX_ kid->op_sibling, FALSE);
			break;
		case OP_ANDASSIGN:
			op->op_ppaddr = da_pp_andassign;
			if (0)
		case OP_ORASSIGN:
			op->op_ppaddr = da_pp_orassign;
			da_lvalue(aTHX_ kid, FALSE);
			kid = kid->op_sibling;
			break;
		case OP_UNSHIFT:
			if (!(tmp = kid->op_sibling)) break; /* array */
			if (!(tmp = tmp->op_sibling)) break; /* first elem */
			op->op_ppaddr = da_pp_unshift;
			goto mod;
		case OP_PUSH:
			if (!(tmp = kid->op_sibling)) break; /* array */
			if (!(tmp = tmp->op_sibling)) break; /* first elem */
			op->op_ppaddr = da_pp_push;
			goto mod;
		case OP_SPLICE:
			if (!(tmp = kid->op_sibling)) break; /* array */
			if (!(tmp = tmp->op_sibling)) break; /* offset */
			if (!(tmp = tmp->op_sibling)) break; /* length */
			if (!(tmp = tmp->op_sibling)) break; /* first elem */
			op->op_ppaddr = da_pp_splice;
			goto mod;
		case OP_ANONLIST:
			if (!(tmp = kid->op_sibling)) break; /* first elem */
			op->op_ppaddr = da_pp_anonlist;
			goto mod;
		case OP_ANONHASH:
			if (!(tmp = kid->op_sibling)) break; /* first elem */
			op->op_ppaddr = da_pp_anonhash;
		 mod:	do MOD(tmp); while ((tmp = tmp->op_sibling));
		}

		if (sib && op->op_sibling) {
			if (kid)
				da_transform(aTHX_ kid, ksib);
			op = op->op_sibling;
		} else {
			op = kid;
			sib = ksib;
		}
	}
}

STATIC int da_peep2(pTHX_ OP *o) {
	OP *sib, *k;
	while (o->op_ppaddr != da_tag_list) {
		while ((sib = o->op_sibling)) {
			if ((o->op_flags & OPf_KIDS) && (k = cUNOPo->op_first)){
				if (da_peep2(aTHX_ k))
					return 1;
			} else switch (o->op_type ? o->op_type : o->op_targ) {
			case OP_SETSTATE:
			case OP_NEXTSTATE:
			case OP_DBSTATE:
				PL_curcop = (COP *) o;
			}
			o = sib;
		}
		if (!(o->op_flags & OPf_KIDS) || !(o = cUNOPo->op_first))
			return 0;
	}
	op_null(o);
	o->op_ppaddr = PL_ppaddr[OP_NULL];
	k = o = cLISTOPo->op_first;
	while ((sib = k->op_sibling))
		k = sib;
	if (!(sib = cUNOPo->op_first) || sib->op_ppaddr != da_tag_rv2cv) {
		Perl_warn(aTHX_ "da peep weirdness 1");
	} else {
		k->op_sibling = sib;
		if (!(k = sib->op_next) || k->op_ppaddr != da_tag_entersub) {
			Perl_warn(aTHX_ "da peep weirdness 2");
		} else {
			k->op_type = OP_ENTERSUB;
			if (sib->op_flags & OPf_SPECIAL) {
				k->op_ppaddr = da_pp_copy;
				da_peep2(aTHX_ o);
			} else {
				da_transform(aTHX_ o, TRUE);
			}
		}
	}
	{
		dDAforce;
		return !--da_peeps;
	}
}

STATIC void da_peep(pTHX_ OP *o) {
	dDAforce;
	da_old_peepp(aTHX_ o);
	ENTER;
	SAVEVPTR(PL_curcop);
	if (da_inside && da_iscope == &cxstack[cxstack_ix]) {
		OP *tmp;
		while ((tmp = o->op_next))
			o = tmp;
		da_transform(aTHX_ o, FALSE);
	} else if (da_peep2(aTHX_ o)) {
		PL_peepp = da_old_peepp;
	}
	LEAVE;
}

#define LEX_NORMAL		10
#define LEX_INTERPNORMAL	 9
#define LEX_KNOWNEXT             0

STATIC OP *da_ck_rv2cv(pTHX_ OP *o) {
	dDA;
	SV **sp;
	OP *kid;
	char *s;
	CV *cv;
	o = da_old_ck_rv2cv(aTHX_ o);
	kid = cUNOPo->op_first;
	if (kid->op_type != OP_GV || !DA_ACTIVE || (
			(cv = GvCV(kGVOP_gv)) != da_cv && cv != da_cvc ))
		return o;
	if (o->op_private & OPpENTERSUB_AMPER)
		return o;
	if (PL_lex_state != LEX_NORMAL && PL_lex_state != LEX_INTERPNORMAL)
		return o; /* not lexing? */
	SvPOK_off(cv);
	s = PL_oldbufptr;
	while (s < PL_bufend && isSPACE(*s)) s++;
	if (memNE(s, PL_tokenbuf, strlen(PL_tokenbuf))) {
		yyerror("da parse weirdness 1");
		return o;
	}
	s += strlen(PL_tokenbuf);
	if (PL_bufptr > s) s = PL_bufptr;
	while (s < PL_bufend && isSPACE(*s)) s++;
	op_null(o);
	o->op_ppaddr = da_tag_rv2cv;
	if (cv == da_cv)
		o->op_flags &= ~OPf_SPECIAL;
	else
		o->op_flags |= OPf_SPECIAL;
	if (*s == '{') { /* here comes deep magic */
		I32 shift;
		PL_bufptr = s;
		PL_expect = XSTATE;
		if ((PL_nexttype[PL_nexttoke++] = yylex()) == '{') {
			PL_nexttype[PL_nexttoke++] = DO;
			sv_setpv((SV *) cv, "$");
		}
		PL_lex_defer = PL_lex_state;
		PL_lex_expect = PL_expect;
		PL_lex_state = LEX_KNOWNEXT;
		if ((shift = s - PL_bufptr)) { /* here comes deeper magic */
			s = SvPVX(PL_linestr);
			PL_bufptr += shift;
			if ((PL_oldbufptr += shift) < s)
				PL_oldbufptr = s;
			if ((PL_oldoldbufptr += shift) < s)
				PL_oldbufptr = s;
			if (PL_last_uni && (PL_last_uni += shift) < s)
				PL_last_uni = s;
			if (PL_last_lop && (PL_last_lop += shift) < s)
				PL_last_lop = s;
			if (shift > 0) {
				STRLEN len = SvCUR(PL_linestr) + 1;
				if (len + shift > SvLEN(PL_linestr))
					len = SvLEN(PL_linestr) - shift;
				Move(s, s + shift, len, char);
				SvCUR(PL_linestr) = len + shift - 1;
			} else {
				STRLEN len = SvCUR(PL_linestr) + shift + 1;
				Move(s - shift, s, len, char);
				SvCUR(PL_linestr) += shift;
			}
			*(PL_bufend = s + SvCUR(PL_linestr)) = '\0';
		}
	}
	if (!da_peeps++) {
		da_old_peepp = PL_peepp;
		PL_peepp = da_peep;
	}
	if (da_iscope != &cxstack[cxstack_ix]) {
		SAVEVPTR(da_iscope);
		SAVEI32(da_inside);
		da_iscope = &cxstack[cxstack_ix];
	}
	SPAGAIN;
	XPUSHs(da_inside ? &PL_sv_yes : &PL_sv_no);
	da_inside = (cv == da_cv);
	PUTBACK;
	return o;
}

STATIC OP *da_ck_entersub(pTHX_ OP *o) {
	dDA;
	OP *kid = cUNOPo->op_first;
	OP *last = kLISTOP->op_last;
	int inside;
	if (!DA_ACTIVE || !(kid->op_flags & OPf_KIDS)
				|| last->op_ppaddr != da_tag_rv2cv)
		return da_old_ck_entersub(aTHX_ o);
	inside = da_inside;
	da_inside = SvIVX(*PL_stack_sp--);
	SvPOK_off(inside ? da_cv : da_cvc);
	op_clear(o);
	Renewc(o, 1, LISTOP, OP);
	o->op_type = inside ? OP_SCOPE : OP_LEAVE;
	o->op_ppaddr = da_tag_entersub;
	cLISTOPo->op_last = kid;
	kid->op_type = OP_LIST;
	kid->op_targ = 0;
	kid->op_ppaddr = da_tag_list;
	kid = kLISTOP->op_first;
	if (inside)
		op_null(kid);
	Renewc(kid, 1, UNOP, OP);
	kUNOP->op_first = last;
	while (kid->op_sibling != last)
		kid = kid->op_sibling;
	kid->op_sibling = Nullop;
	cLISTOPx(cUNOPo->op_first)->op_last = kid;
	if (kid->op_type == OP_NULL && inside)
		kid->op_flags &= ~OPf_SPECIAL;
	last->op_next = o;
	return o;
}

STATIC MAGIC *mg_extract(SV *sv, int type) {
	MAGIC **mgp, *mg;
	for (mgp = &SvMAGIC(sv); (mg = *mgp); mgp = &mg->mg_moremagic) {
		if (mg->mg_type == type) {
			*mgp = mg->mg_moremagic;
			mg->mg_moremagic = NULL;
			return mg;
		}
	}
	return NULL;
}


MODULE = Data::Alias  PACKAGE = Data::Alias

PROTOTYPES: DISABLE

BOOT:
	{
	static int initialized = 0;
	dDA;
	OP_REFCNT_LOCK;
	DA_INIT;
	da_cv = get_cv("Data::Alias::alias", TRUE);
	da_cvc = get_cv("Data::Alias::copy", TRUE);
	if (!initialized++) {
		da_old_ck_rv2cv = PL_check[OP_RV2CV];
		PL_check[OP_RV2CV] = da_ck_rv2cv;
		da_old_ck_entersub = PL_check[OP_ENTERSUB];
		PL_check[OP_ENTERSUB] = da_ck_entersub;
	}
	OP_REFCNT_UNLOCK;
	CvLVALUE_on(get_cv("Data::Alias::deref", TRUE));
	}

void
deref(...)
    PREINIT:
	I32 i, n = 0;
	SV *sv;
    PPCODE:
	for (i = 0; i < items; i++) {
		if (!SvROK(ST(i))) {
			STRLEN z;
			if (SvOK(ST(i)))
				Perl_croak(aTHX_ DA_DEREF_ERR, SvPV(ST(i), z));
			if (ckWARN(WARN_UNINITIALIZED))
				Perl_warner(aTHX_ packWARN(WARN_UNINITIALIZED),
					"Use of uninitialized value in deref");
			continue;
		}
		sv = SvRV(ST(i));
		switch (SvTYPE(sv)) {
			I32 x;
		case SVt_PVAV:
			if (!(x = av_len((AV *) sv) + 1))
				continue;
			SP += x;
			break;
		case SVt_PVHV:
			if (!(x = HvKEYS(sv)))
				continue;
			SP += x * 2;
			break;
		case SVt_PVCV:
			Perl_croak(aTHX_ "Can't deref subroutine reference");
		case SVt_PVFM:
			Perl_croak(aTHX_ "Can't deref format reference");
		case SVt_PVIO:
			Perl_croak(aTHX_ "Can't deref filehandle reference");
		default:
			SP++;
		}
		ST(n++) = ST(i);
	}
	EXTEND(SP, 0);
	for (i = 0; n--; ) {
		SV *sv = SvRV(ST(n));
		I32 x = SvTYPE(sv);
		if (x == SVt_PVAV) {
			i -= x = AvFILL((AV *) sv) + 1;
			Copy(AvARRAY((AV *) sv), SP + i + 1, x, SV *);
		} else if (x == SVt_PVHV) {
			HE *entry;
			HV *hv = (HV *) sv;
			i -= x = hv_iterinit(hv) * 2;
			PUTBACK;
			while ((entry = hv_iternext(hv))) {
				sv = hv_iterkeysv(entry);
				SPAGAIN;
				SvREADONLY_on(sv);
				SP[++i] = sv;
				sv = hv_iterval(hv, entry);
				SPAGAIN;
				SP[++i] = sv;
			}
			i -= x;
		} else {
			SP[i--] = sv;
		}
	}
