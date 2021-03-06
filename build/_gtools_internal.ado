*! version 0.4.2 21Nov2017 Mauricio Caceres Bravo, mauricio.caceres.bravo@gmail.com
*! Encode varlist using Jenkin's 128-bit spookyhash via C plugins

capture program drop _gtools_internal
program _gtools_internal, rclass
    version 13
    global GTOOLS_USER_INTERNAL_VARABBREV `c(varabbrev)'
    set varabbrev off

    if ( inlist("${GTOOLS_FORCE_PARALLEL}", "17900") ) {
        di as txt "(note: multi-threading is not available on this platform)"
    }

    local GTOOLS_CALLER $GTOOLS_CALLER
    local GTOOLS_CALLERS gegen        ///
                         gcollapse    ///
                         gisid        /// 2
                         hashsort     /// 3
                         glevelsof    ///
                         gunique      ///
                         gtoplevelsof ///
                         gcontract    /// 8
                         gquantiles

    if ( !(`:list GTOOLS_CALLER in GTOOLS_CALLERS') ) {
        di as err "_gtools_internal is not meant to be called directly." ///
                  " See {help gtools}"
        clean_all 198
        exit 198
    }

    if ( `=_N < 1' ) {
        di as err "no observations"
        clean_all 17001
        exit 17001
    }

    local 00 `0'

    * Time the entire function execution
    gtools_timer on 99
    gtools_timer on 98

    ***********************************************************************
    *                           Syntax parsing                            *
    ***********************************************************************

    syntax [anything] [if] [in] , ///
    [                             ///
        DEBUG_level(int 0)        /// debugging
        Verbose                   /// info
        BENCHmark                 /// print function benchmark info
        BENCHmarklevel(int 0)     /// print plugin benchmark info
        HASHmethod(str)           /// hashing method
        hashlib(str)              /// path to hash library (Windows only)
        oncollision(str)          /// On collision, fall back or throw error
        gfunction(str)            /// Program to handle collision
        replace                   /// Replace variables, if they exist
                                  ///
                                  /// General options
                                  /// ---------------
                                  ///
        seecount                  /// print group info to console
        COUNTonly                 /// report group info and exit
        MISSing                   /// Include missing values
        unsorted                  /// Do not sort hash values; faster
        countmiss                 /// count # missing in output
                                  /// (only w/certain targets)
                                  ///
                                  /// Generic stats options
                                  /// ---------------------
                                  ///
        sources(str)              /// varlist must exist
        targets(str)              /// varlist must exist
        stats(str)                /// stats, 1 per target. w/multiple targets,
                                  /// # targets must = # sources
        freq(str)                 /// also collapse frequencies to variable
        ANYMISSing(str)           /// Value if any missing per stat per group
        ALLMISSing(str)           /// Value if all missing per stat per group
                                  ///
                                  /// Capture options
                                  /// ---------------
                                  ///
        gquantiles(str)           /// options for gquantiles (to parse later)
        gcontract(str)            /// options for gcontract (to parse later)
        gcollapse(str)            /// options for gcollapse (to parse later)
        gtop(str)                 /// options for gtop (to parse later)
        recast(str)               /// bulk recast
                                  ///
                                  /// gegen group options
                                  /// -------------------
                                  ///
        tag(str)                  /// 1 for first obs of group in range, 0 otherwise
        GENerate(str)             /// variable where to store encoded index
        counts(str)               /// variable where to store group counts
        fill(str)                 /// for counts(); group fill order or value
                                  ///
                                  /// gisid options
                                  /// -------------
                                  ///
        EXITMissing               /// Throw error if any missing values (by row).
                                  ///
                                  /// hashsort options
                                  /// ----------------
                                  ///
        invertinmata              /// invert sort index using mata
        sortindex(str)            /// keep sort index in memory
        sortgen                   /// sort by generated variable (hashsort only)
        skipcheck                 /// skip is sorted check
                                  ///
                                  /// glevelsof options
                                  /// -----------------
                                  ///
        glevelsof(str)            /// extra options for glevelsof (parse later)
        Separate(str)             /// Levels sepparator
        COLSeparate(str)          /// Columns sepparator
        Clean                     /// Clean strings
        numfmt(str)               /// Columns sepparator
    ]

    if ( `benchmarklevel' > 0 ) local benchmark benchmark
    local ifin `if' `in'
    local gen  `generate'

    local hashmethod `hashmethod'
    if ( `"`hashmethod'"' == "" ) local hashmethod 0


    local hashmethod_list 0 1 2 default biject spooky
    if ( !`:list hashmethod_list in hashmethod_list' ) {
        di as err `"hash method '`hashmethod'' not known;"' ///
                   " specify 0 (default), 1 (biject), or 2 (spooky)"
        clean_all 198
        exit 198
    }

    if ( "`hashmethod'" == "default" ) local hashmethod 0
    if ( "`hashmethod'" == "biject"  ) local hashmethod 1
    if ( "`hashmethod'" == "spooky"  ) local hashmethod 2

    * Check you will find the hash library (Windows only)
    * ---------------------------------------------------

    local url https://raw.githubusercontent.com/mcaceresb/stata-gtools
    local url `url'/master/spookyhash.dll

    if ( "`hashlib'" == "" ) {
        local hashlib `c(sysdir_plus)'s/spookyhash.dll
        local hashusr 0
    }
    else local hashusr 1
    if ( ("`c_os_'" == "windows") & `hashusr' ) {
        cap confirm file spookyhash.dll
        if ( _rc | `hashusr' ) {
            cap findfile spookyhash.dll
            if ( _rc | `hashusr' ) {
                cap confirm file `"`hashlib'"'
                if ( _rc ) {
                    di as err `"'`hashlib'' not found."'
                    di as err `"Download {browse "`url'":here}"' ///
                              `" or run {opt gtools, dependencies}"'
                    clean_all 198
                    exit 198
                }
            }
            else local hashlib `r(fn)'
            mata: __gtools_hashpath = ""
            mata: __gtools_dll = ""
            mata: pathsplit(`"`hashlib'"', __gtools_hashpath, __gtools_dll)
            mata: st_local("__gtools_hashpath", __gtools_hashpath)
            mata: mata drop __gtools_hashpath
            mata: mata drop __gtools_dll
            local path: env PATH
            if inlist(substr(`"`path'"', length(`"`path'"'), 1), ";") {
                mata: st_local("path", substr(`"`path'"', 1, `:length local path' - 1))
            }
            local __gtools_hashpath: subinstr local __gtools_hashpath "/" "\", all
            local newpath `"`path';`__gtools_hashpath'"'
            local truncate 2048
            if ( `:length local newpath' > `truncate' ) {
                local loops = ceil(`:length local newpath' / `truncate')
                mata: __gtools_pathpieces = J(1, `loops', "")
                mata: __gtools_pathcall   = ""
                mata: for(k = 1; k <= `loops'; k++) __gtools_pathpieces[k] = substr(st_local("newpath"), 1 + (k - 1) * `truncate', `truncate')
                mata: for(k = 1; k <= `loops'; k++) __gtools_pathcall = __gtools_pathcall + " `" + `"""' + __gtools_pathpieces[k] + `"""' + "' "
                mata: st_local("pathcall", __gtools_pathcall)
                mata: mata drop __gtools_pathcall __gtools_pathpieces
                cap plugin call env_set, PATH `pathcall'
            }
            else {
                cap plugin call env_set, PATH `"`path';`__gtools_hashpath'"'
            }
            if ( _rc ) {
                local rc = _rc
                di as err "Unable to add '`__gtools_hashpath'' to system PATH."
                clean_all `rc'
                exit `rc'
            }
        }
        else local hashlib spookyhash.dll
    }

    ***********************************************************************
    *                             Bulk recast                             *
    ***********************************************************************

    if ( "`recast'" != "" ) {
        local 0  , `recast'
        syntax, sources(varlist) targets(varlist)
        if ( `:list sizeof sources' != `:list sizeof targets' ) {
            di as err "Must specify the same number of sources and targets"
            clean_all 198
            exit 198
        }
        scalar __gtools_k_recast = `:list sizeof sources'
        cap noi plugin call gtools_plugin `targets' `sources', recast
        local rc = _rc
        cap scalar drop __gtools_k_recast
        clean_all `rc'
        exit `rc'
    }

    ***********************************************************************
    *                    Execute the function normally                    *
    ***********************************************************************

    * What to do
    * ----------

    local gfunction_list hash     ///
                         egen     ///
                         levelsof ///
                         isid     ///
                         sort     ///
                         unique   ///
                         collapse ///
                         top      ///
                         contract ///
                         quantiles

    if ( "`gfunction'" == "" ) local gfunction hash
    if ( !(`:list gfunction in gfunction_list') ) {
        di as err "{opt gfunction()} was '`gfunction''; expected one of:" ///
                  " `gfunction_list'"
        clean_all 198
        exit 198
    }

    * Switches, options
    * -----------------

    local website_url  https://github.com/mcaceresb/stata-gtools/issues
    local website_disp github.com/mcaceresb/stata-gtools

    if ( "`oncollision'" == "" ) local oncollision fallback
    if ( !inlist("`oncollision'", "fallback", "error") ) {
        di as err "option {opt oncollision()} must be 'fallback' or 'error'"
        clean_all 198
        exit 198
    }

    * Check options compatibility
    * ---------------------------

    if ( inlist("`gfunction'", "isid", "unique") ) {
        if ( "`unsorted'" == "" ) {
            di as txt "({opt gfunction(`gfunction')} sets option" ///
                      " {opt unsorted} automatically)"
            local unsorted unsorted
        }
    }

    if ( inlist("`gfunction'", "isid") ) {
        if ( "`exitmissing'`missing'" == "" ) {
            di as err "{opt gfunction(`gfunction')} must set either" ///
                      " {opt exitmissing} or {opt missing}"
            clean_all 198
            exit 198
        }
    }

    if ( inlist("`gfunction'", "sort") ) {
        if ( "`if'" != "" ) {
            di as err "Cannot sort data with if condition"
            clean_all 198
            exit 198
        }
        if ( "`exitmissing'" != "" ) {
            di as err "Cannot specify {opt exitmissing} with" ///
                      " {opt gfunction(sort)}"
            clean_all 198
            exit 198
        }
        if ( "`missing'" == "" ) {
            di as txt "({opt gfunction(`gfunction')} sets option" ///
                      " {opt missing} automatically)"
            local missing missing
        }
        if ( "`unsorted'" != "" ) {
            di as err "Cannot specify {opt unsorted} with {opt gfunction(sort)}"
            clean_all 198
            exit 198
        }
    }

    if ( ("`exitmissing'" != "") & ("`missing'" != "") ) {
        di as err "Cannot specify {opt exitmissing} with option {opt missing}"
        clean_all 198
        exit 198
    }

    if ( "`sortindex'" != "" ) {
        if ( !inlist("`gfunction'", "sort") ) {
            di as err "sort index only allowed with {opt gfunction(sort)}"
            clean_all 198
            exit 198
        }
    }

    if ( "`counts'`gen'`tag'" != "" ) {
        if ( "`countonly'" != "" ) {
            di as err "cannot generate targets with option {opt countonly}"
            clean_all 198
            exit 198
        }

        local gen_list hash egen unique sort levelsof quantiles
        if ( !`:list gfunction in gen_list' ) {
            di as err "cannot generate targets with" ///
                      " {opt gfunction(`gfunction')}"
            clean_all 198
            exit 198
        }

        if ( ("`gen'" == "") & !inlist("`gfunction'", "sort", "levelsof") ) {
            if ( "`unsorted'" == "" ) {
                di as txt "({opt tag} and {opt counts} without {opt gen}" ///
                           " sets option {opt unsorted} automatically)"
                local unsorted unsorted
            }
        }
    }

    if ( "`sources'`targets'`stats'" != "" ) {
        if ( !inlist("`gfunction'", "hash", "egen", "collapse", "unique") ) {
            di as err "cannot generate targets with {opt gfunction(`gfunction')}"
            clean_all 198
            exit 198
        }
    }

    if ( "`fill'" != "" ) {
        if ( "`counts'`targets'" == "" ) {
            di as err "{opt fill()} only allowed with {opth counts(newvarname)}"
            clean_all 198
            exit 198
        }
    }

    if ( "`separate'`colseparate'`clean'`numfmt'" != "" ) {
        local errmsg ""
        if ( "`separate'"    != "" ) local errmsg "`errmsg' separate(),"
        if ( "`colseparate'" != "" ) local errmsg "`errmsg' colseparate(), "
        if ( "`clean'"       != "" ) local errmsg "`errmsg' -clean-, "
        if ( "`numfmt'"      != "" ) local errmsg "`errmsg' -numfmt()-, "
        if ( !inlist("`gfunction'", "levelsof", "top") ) {
            di as err "`errmsg' only allowed with {opt gfunction(levelsof)}"
            clean_all 198
            exit 198
        }
    }

    * Parse options into scalars, etc. for C
    * --------------------------------------

    local any_if    = ( "if'"         != "" )
    local verbose   = ( "`verbose'"   != "" )
    local benchmark = ( "`benchmark'" != "" )

    scalar __gtools_init_targ   = 0
    scalar __gtools_any_if      = `any_if'
    scalar __gtools_verbose     = `verbose'
    scalar __gtools_debug       = `debug_level'
    scalar __gtools_benchmark   = cond(`benchmarklevel' > 0, `benchmarklevel', 0)
    scalar __gtools_missing     = ( "`missing'"      != "" )
    scalar __gtools_unsorted    = ( "`unsorted'"     != "" )
    scalar __gtools_countonly   = ( "`countonly'"    != "" )
    scalar __gtools_seecount    = ( "`seecount'"     != "" )
    scalar __gtools_nomiss      = ( "`exitmissing'"  != "" )
    scalar __gtools_replace     = ( "`replace'"      != "" )
    scalar __gtools_countmiss   = ( "`countmiss'"    != "" )
    scalar __gtools_invertix    = ( "`invertinmata'" == "" )
    scalar __gtools_skipcheck   = ( "`skipcheck'"    != "" )
    scalar __gtools_hash_method = `hashmethod'

    scalar __gtools_top_ntop        = 0
    scalar __gtools_top_pct         = 0
    scalar __gtools_top_freq        = 0
    scalar __gtools_top_miss        = 0
    scalar __gtools_top_groupmiss   = 0
    scalar __gtools_top_other       = 0
    scalar __gtools_top_lmiss       = 0
    scalar __gtools_top_lother      = 0
    matrix __gtools_top_matrix      = J(1, 5, .)
    matrix __gtools_top_num         = J(1, 1, .)
    matrix __gtools_contract_which  = J(1, 4, 0)
    matrix __gtools_invert          = 0

    scalar __gtools_levels_return   = 1

    scalar __gtools_xtile_xvars     = 0
    scalar __gtools_xtile_nq        = 0
    scalar __gtools_xtile_nq2       = 0
    scalar __gtools_xtile_cutvars   = 0
    scalar __gtools_xtile_ncuts     = 0
    scalar __gtools_xtile_qvars     = 0
    scalar __gtools_xtile_gen       = 0
    scalar __gtools_xtile_pctile    = 0
    scalar __gtools_xtile_genpct    = 0
    scalar __gtools_xtile_pctpct    = 0
    scalar __gtools_xtile_altdef    = 0
    scalar __gtools_xtile_missing   = 0
    scalar __gtools_xtile_strict    = 0
    scalar __gtools_xtile_min       = 0
    scalar __gtools_xtile_max       = 0
    scalar __gtools_xtile_method    = 0
    scalar __gtools_xtile_bincount  = 0
    scalar __gtools_xtile__pctile   = 0
    scalar __gtools_xtile_dedup     = 0
    scalar __gtools_xtile_cutifin   = 0
    scalar __gtools_xtile_cutby     = 0
    scalar __gtools_xtile_imprecise = 0
    matrix __gtools_xtile_quantiles = J(1, 1, .)
    matrix __gtools_xtile_cutoffs   = J(1, 1, .)
    matrix __gtools_xtile_quantbin  = J(1, 1, .)
    matrix __gtools_xtile_cutbin    = J(1, 1, .)

    * Parse glevelsof options
    * -----------------------

    if ( `"`separate'"' == "" ) local sep `" "'
	else local sep `"`separate'"'

    if ( `"`colseparate'"' == "" ) local colsep `" | "'
	else local colsep `"`colseparate'"'

    if ( `"`numfmt'"' == "" ) {
        local numfmt `"%.16g"'
    }

    if regexm(`"`numfmt'"', "%([0-9]+)\.([0-9]+)([gf])") {
        local numlen = max(`:di regexs(1)', `:di regexs(2)' + 5) + cond(regexs(3) == "f", 23, 0)
    }
    else if regexm(`"`numfmt'"', "%\.([0-9]+)([gf])") {
        local numlen = `:di regexs(1)' + 5 + cond(regexs(2) == "f", 23, 0)
    }
    else {
        di as err "Number format must be %(width).(digits)(f|g);" ///
                  " e.g. %.16g (default), %20.5f"
        clean_all 198
        exit 198
    }

    scalar __gtools_numfmt_max = `numlen'
    scalar __gtools_numfmt_len = length(`"`numfmt'"')
    scalar __gtools_cleanstr   = ( "`clean'" != "" )
    scalar __gtools_sep_len    = length(`"`sep'"')
    scalar __gtools_colsep_len = length(`"`colsep'"')

    * Parse target names and group fill
    * ---------------------------------

    * confirm new variable `gen_name'
    * local 0 `gen_name'
    * syntax newvarname

    if ( "`tag'" != "" ) {
        gettoken tag_type tag_name: tag
        local tag_name `tag_name'
        local tag_type `tag_type'
        if ( "`tag_name'" == "" ) {
            local tag_name `tag_type'
            local tag_type byte
        }
        cap noi confirm_var `tag_name', `replace'
        if ( _rc ) {
            local rc = _rc
            clean_all `rc'
            exit `rc'
        }
        local new_tag = `r(newvar)'
    }

    if ( "`gen'" != "" ) {
        gettoken gen_type gen_name: gen
        local gen_name `gen_name'
        local gen_type `gen_type'
        if ( "`gen_name'" == "" ) {
            local gen_name `gen_type'
            if ( `=_N < maxlong()' ) {
                local gen_type long
            }
            else {
                local gen_type double
            }
        }
        cap noi confirm_var `gen_name', `replace'
        if ( _rc ) {
            local rc = _rc
            clean_all `rc'
            exit `rc'
        }
        local new_gen = `r(newvar)'
    }

    scalar __gtools_group_data = 0
    scalar __gtools_group_fill = 0
    scalar __gtools_group_val  = .
    if ( "`counts'" != "" ) {
        {
            gettoken counts_type counts_name: counts
            local counts_name `counts_name'
            local counts_type `counts_type'
            if ( "`counts_name'" == "" ) {
                local counts_name `counts_type'
                if ( `=_N < maxlong()' ) {
                    local counts_type long
                }
                else {
                    local counts_type double
                }
            }
            cap noi confirm_var `counts_name', `replace'
            if ( _rc ) {
                local rc = _rc
                clean_all
                exit `rc'
            }
            local new_counts = `r(newvar)'
        }
        if ( "`fill'" != "" ) {
            if ( "`fill'" == "group" ) {
                scalar __gtools_group_fill = 0
                scalar __gtools_group_val  = .
            }
            else if ( "`fill'" == "data" ) {
                scalar __gtools_group_data = 1
                scalar __gtools_group_fill = 0
                scalar __gtools_group_val  = .
            }
            else {
                cap confirm number `fill'
                cap local fill_value = `fill'
                if ( _rc ) {
                    di as error "'`fill'' found where number expected"
                    clean_all 7
                    exit 7
                }
                * local 0 , fill(`fill')
                * syntax , [fill(real 0)]
                scalar __gtools_group_fill = 1
                scalar __gtools_group_val  = `fill'
            }
        }
    }
    else if ( "`targets'" != "" ) {
        if ( "`fill'" != "" ) {
            if ( "`fill'" == "missing" ) {
                scalar __gtools_group_fill = 1
                scalar __gtools_group_val  = .
            }
            else if ( "`fill'" == "data" ) {
                scalar __gtools_group_data = 1
                scalar __gtools_group_fill = 0
                scalar __gtools_group_val  = .
            }
        }
    }
    else if ( "`fill'" != "" ) {
        di as err "{opt fill} only allowed with option {opt count()} or {opt targets()}"
        clean_all 198
        exit 198
    }

    * Generate new variables
    * ----------------------

    local kvars_group = 0
    scalar __gtools_encode  = 1
    mata:  __gtools_group_targets = J(1, 3, 0)
    mata:  __gtools_group_init    = J(1, 3, 0)
    mata:  __gtools_togen_k = 0

    if ( "`counts'`gen'`tag'" != "" ) {
        local topos 1
        local etargets `gen_name' `counts_name' `tag_name'
        mata: __gtools_togen_types = J(1, `:list sizeof etargets', "")
        mata: __gtools_togen_names = J(1, `:list sizeof etargets', "")

        * 111 = 8
        * 101 = 6
        * 011 = 7
        * 001 = 5
        * 110 = 4
        * 010 = 3
        * 100 = 2
        * 000 = 1

        if ( "`gen'" != "" ) {
            local ++kvars_group
            scalar __gtools_encode = __gtools_encode + 1
            if ( `new_gen' ) {
                mata: __gtools_togen_types[`topos'] = "`gen_type'"
                mata: __gtools_togen_names[`topos'] = "`gen_name'"
                local ++topos
            }
            else {
                mata:  __gtools_group_init[1] = 1
            }
            mata: __gtools_group_targets = J(1, 3, 1)
        }

        if ( "`counts'" != "" ) {
            local ++kvars_group
            scalar __gtools_encode = __gtools_encode + 2
            if ( `new_counts' ) {
                mata: __gtools_togen_types[`topos'] = "`counts_type'"
                mata: __gtools_togen_names[`topos'] = "`counts_name'"
                local ++topos
            }
            else {
                mata:  __gtools_group_init[2] = 1
            }
            mata: __gtools_group_targets[2] = __gtools_group_targets[2] + 1
            mata: __gtools_group_targets[3] = __gtools_group_targets[3] + 1
        }
        else {
            mata: __gtools_group_targets[2] = 0
        }

        if ( "`tag'" != "" ) {
            local ++kvars_group
            scalar __gtools_encode = __gtools_encode + 4
            if ( `new_tag' ) {
                mata: __gtools_togen_types[`topos'] = "`tag_type'"
                mata: __gtools_togen_names[`topos'] = "`tag_name'"
                local ++topos
            }
            else {
                mata:  __gtools_group_init[3] = 1
            }
            mata: __gtools_group_targets[3] = __gtools_group_targets[3] + 1
        }
        else {
            mata: __gtools_group_targets[3] = 0
        }

        qui mata: __gtools_togen_k = sum(__gtools_togen_names :!= missingof(__gtools_togen_names))
        qui mata: __gtools_togen_s = 1::((__gtools_togen_k > 0)? __gtools_togen_k: 1)
        qui mata: (__gtools_togen_k > 0)? st_addvar(__gtools_togen_types[__gtools_togen_s], __gtools_togen_names[__gtools_togen_s]): ""

        local msg "Generated targets"
        gtools_timer info 98 `"`msg'"', prints(`benchmark')
    }
    else local etargets ""

    scalar __gtools_k_group = `kvars_group'
    mata: st_matrix("__gtools_group_targets", __gtools_group_targets)
    mata: st_matrix("__gtools_group_init",    __gtools_group_init)
    mata: mata drop __gtools_group_targets
    mata: mata drop __gtools_group_init

    * Parse by types
    * --------------

    if ( "`anything'" != "" ) {
        local clean_anything `anything'
        local clean_anything: subinstr local clean_anything "+" "", all
        local clean_anything: subinstr local clean_anything "-" "", all
        local clean_anything `clean_anything'
        cap ds `clean_anything'
        if ( _rc | ("`clean_anything'" == "") ) {
            local rc = _rc
            di as err "Malformed call: '`anything''"
            di as err "Syntax: [+|-]varname [[+|-]varname ...]"
            clean_all 111
            exit 111
        }
        local clean_anything `r(varlist)'
        cap noi check_matsize `clean_anything'
        if ( _rc ) {
            local rc = _rc
            clean_all `rc'
            exit `rc'
        }
    }

    cap noi parse_by_types `anything' `ifin', clean_anything(`clean_anything')
    if ( _rc ) {
        local rc = _rc
        clean_all `rc'
        exit `rc'
    }

    local invert = `r(invert)'
    local byvars = "`r(varlist)'"
    local bynum  = "`r(varnum)'"
    local bystr  = "`r(varstr)'"

    if ( "`byvars'" != "" ) {
        cap noi check_matsize `byvars'
        if ( _rc ) {
            local rc = _rc
            clean_all `rc'
            exit `rc'
        }
    }

    if ( "`targets'" != "" ) {
        cap noi check_matsize `targets'
        if ( _rc ) {
            local rc = _rc
            clean_all `rc'
            exit `rc'
        }
    }

    if ( "`sources'" != "" ) {
        cap noi check_matsize `sources'
        if ( _rc ) {
            local rc = _rc
            clean_all `rc'
            exit `rc'
        }
    }

    if ( inlist("`gfunction'", "levelsof") & ("`byvars'" == "") ) {
        di as err "gfunction(`gfunction') requires at least one variable."
        clean_all 198
        exit 198
    }

    * Parse position of by variables
    * ------------------------------

    if ( "`byvars'" != "" ) {
        cap matrix drop __gtools_strpos
        cap matrix drop __gtools_numpos

        foreach var of local bystr {
            matrix __gtools_strpos = nullmat(__gtools_strpos), ///
                                    `:list posof `"`var'"' in byvars'
        }

        foreach var of local bynum {
            matrix __gtools_numpos = nullmat(__gtools_numpos), ///
                                     `:list posof `"`var'"' in byvars'
        }
    }
    else {
        matrix __gtools_strpos = 0
        matrix __gtools_numpos = 0
    }

    * Parse sources, targets, stats (sources and targets MUST exist!)
    * ---------------------------------------------------------------

    matrix __gtools_stats        = 0
    matrix __gtools_pos_targets  = 0
    scalar __gtools_k_vars       = 0
    scalar __gtools_k_targets    = 0
    scalar __gtools_k_stats      = 0

    if ( "`sources'`targets'`stats'" != "" ) {
        if ( "`gfunction'" == "collapse" ) {
            if regexm("`gcollapse'", "^(forceio|switch)") {
                local k_exist k_exist(sources)
            }
            if regexm("`gcollapse'", "^read") {
                local k_exist k_exist(targets)
            }
        }

        parse_targets, sources(`sources') ///
                       targets(`targets') ///
                       stats(`stats') `k_exist'

        if ( _rc ) {
            local rc = _rc
            clean_all `rc'
            exit `rc'
        }

        if ( "`freq'" != "" ) {
            cap confirm variable `freq'
            if ( _rc ) {
                di as err "Target `freq' has to exist."
                clean_all 198
                exit 198
            }

            cap confirm numeric variable `freq'
            if ( _rc ) {
                di as err "Target `freq' must be numeric."
                clean_all 198
                exit 198
            }

            scalar __gtools_k_targets    = __gtools_k_targets + 1
            scalar __gtools_k_stats      = __gtools_k_stats   + 1
            matrix __gtools_stats        = __gtools_stats,        -14
            matrix __gtools_pos_targets  = __gtools_pos_targets,  0
        }

        local intersection: list __gtools_targets & byvars
        if ( "`intersection'" != "" ) {
            if ( "`replace'" == "" ) {
                di as error "targets in are also in by(): `intersection'"
                error 110
            }
        }

        local extravars `__gtools_sources' `__gtools_targets' `freq'
    }
    else local extravars ""

    local msg "Parsed by variables"
    gtools_timer info 98 `"`msg'"', prints(`benchmark')

    * Custom handle any missing or all missing values
    * -----------------------------------------------

    if ( "`anymissing'" != "" ) {
        di as err "anymissing() is planned for a future release."
        clean_all 198
        exit 198
    }

    if ( "`allmissing'" != "" ) {
        di as err "allmissing() is planned for a future release."
        clean_all 198
        exit 198
    }

    ***********************************************************************
    *                           Call the plugin                           *
    ***********************************************************************

    local rset = 1
    local opts oncollision(`oncollision')
    if ( "`gfunction'" == "sort" ) {

        * Andrew Mauer's trick? From ftools
        * ---------------------------------

        local contained 0
        local sortvar : sortedby
        forvalues k = 1 / `:list sizeof byvars' {
            if ( "`:word `k' of `byvars''" == "`:word `k' of `sortvar''" ) {
                local ++contained
            }
        }
        * di "`contained'"

        * Check if already sorted
        if ( "`skipcheck'" == "" ) {
            if ( !`invert' & ("`sortvar'" == "`byvars'") ) {
                if ( "`verbose'" != "" ) di as txt "(already sorted)"
                clean_all 0
                exit 0
            }
            else if ( !`invert' & (`contained' == `:list sizeof byvars') ) {
                * If the first k sorted variables equal byvars, just call sort
                if ( "`verbose'" != "" ) di as txt "(already sorted)"
                sort `byvars' // , stable
                clean_all 0
                exit 0
            }
            else if ( "`sortvar'" != "" ) {
                * Andrew Maurer's trick to clear `: sortedby'
                qui set obs `=_N + 1'
                loc sortvar : word 1 of `sortvar'
                loc sortvar_type : type `sortvar'
                loc sortvar_is_str = strpos("`sortvar_type'", "str") == 1

                if ( `sortvar_is_str' ) {
                    qui replace `sortvar' = `"."' in `=_N'
                }
                else {
                    qui replace `sortvar' = 0 in `=_N'
                }
                qui drop in `=_N'
            }
        }
        else {
            if ( "`sortvar'" != "" ) {
                * Andrew Maurer's trick to clear `: sortedby'
                qui set obs `=_N + 1'
                loc sortvar : word 1 of `sortvar'
                loc sortvar_type : type `sortvar'
                loc sortvar_is_str = strpos("`sortvar_type'", "str") == 1

                if ( `sortvar_is_str' ) {
                    qui replace `sortvar' = `"."' in `=_N'
                }
                else {
                    qui replace `sortvar' = 0 in `=_N'
                }
                qui drop in `=_N'
            }
        }

        * Use sortindex for the shuffle
        * -----------------------------

        local hopts benchmark(`benchmark') `invertinmata'
        cap noi hashsort_inner `byvars' `etargets', `hopts'
        cap noi rc_dispatch `byvars', rc(`=_rc') `opts'
        if ( _rc ) {
            local rc = _rc
            clean_all `rc'
            exit `rc'
        }

        if ( ("`gen_name'" == "") | ("`sortgen'" == "") ) {
            if ( `invert' ) {
                mata: st_numscalar("__gtools_first_inverted", ///
                                   selectindex(st_matrix("__gtools_invert"))[1])
                if ( `=scalar(__gtools_first_inverted)' > 1 ) {
                    local sortvars ""
                    forvalues i = 1 / `=scalar(__gtools_first_inverted) - 1' {
                        local sortvars `sortvars' `:word `i' of `byvars''
                    }
                    scalar drop __gtools_first_inverted
                    sort `sortvars' // , stable
                }
            }
            else {
                sort `byvars' // , stable
            }
        }
        else if ( ("`gen_name'" != "") & ("`sortgen'" != "") ) {
            sort `gen_name' // , stable
        }

        local msg "Stata reshuffle"
        gtools_timer info 98 `"`msg'"', prints(`benchmark') off

        if ( `=_N < maxlong()' ) {
            local stype long
        }
        else {
            stype double
        }
        if ( "`sortindex'" != "" ) gen `stype' `sortindex' = _n
    }
    else if ( "`gfunction'" == "collapse" ) {
        local 0 `gcollapse'
        syntax anything, [st_time(real 0) fname(str) ixinfo(str) merge]
        scalar __gtools_st_time   = `st_time'
        scalar __gtools_used_io   = 0
        scalar __gtools_ixfinish  = 0
        scalar __gtools_J         = _N
        scalar __gtools_init_targ = ( "`ifin'" != "" ) & ("`merge'" != "")

        if inlist("`anything'", "forceio", "switch") {
            local extravars `__gtools_sources' `__gtools_sources' `freq'
        }
        if inlist("`anything'", "read") {
            local extravars `: list __gtools_targets - __gtools_sources' `freq'
        }

        local plugvars `byvars' `etargets' `extravars' `ixinfo'
        cap noi plugin call gtools_plugin `plugvars' `ifin', ///
            collapse `anything' `"`fname'"'
        cap noi rc_dispatch `byvars', rc(`=_rc') `opts'
        if ( _rc ) {
            local rc = _rc
            clean_all `rc'
            exit `rc'
        }

        if ( "`anything'" != "read" ) {
            scalar __gtools_J  = `r_J'
            return scalar N    = `r_N'
            return scalar J    = `r_J'
            return scalar minJ = `r_minJ'
            return scalar maxJ = `r_maxJ'
            local rset = 0
        }

        if ( `=scalar(__gtools_ixfinish)' ) {
            local msg "Switch code runtime"
            gtools_timer info 98 `"`msg'"', prints(`benchmark')

            qui mata: st_addvar(__gtools_gc_addtypes, __gtools_gc_addvars, 1)
            local msg "Added targets"
            gtools_timer info 98 `"`msg'"', prints(`benchmark')

            local extravars `__gtools_sources' `__gtools_targets' `freq'
            local plugvars `byvars' `etargets' `extravars' `ixinfo'
            cap noi plugin call gtools_plugin `plugvars' `ifin', ///
                collapse ixfinish `"`fname'"'
            if ( _rc ) {
                local rc = _rc
                clean_all `rc'
                exit `rc'
            }

            local msg "Finished collapse"
            gtools_timer info 98 `"`msg'"', prints(`benchmark') off
        }
        else {
            local msg "Plugin runtime"
            gtools_timer info 98 `"`msg'"', prints(`benchmark') off
        }

        return scalar used_io = `=scalar(__gtools_used_io)'
        local runtxt " (internals)"
    }
    else {
        if ( inlist("`gfunction'", "unique", "egen") ) {
            local gcall hash
        }
        else if ( inlist("`gfunction'",  "contract") ) {
            local 0 `gcontract'
            syntax varlist, contractwhich(numlist)
            local gcall `gfunction'
            local contractvars `varlist'
            mata: st_matrix("__gtools_contract_which", ///
                            strtoreal(tokens(`"`contractwhich'"')))
            local runtxt " (internals)"
        }
        else if ( inlist("`gfunction'",  "levelsof") ) {
            local 0, `glevelsof'
            syntax, [noLOCALvar freq(str) store(str)]
            local gcall `gfunction'
            scalar __gtools_levels_return = ( "`localvar'" == "" )

            if ( "`store'" != "" ) {
                di as err "store() is planned for a future release."
                clean_all 198
                exit 198
            }

            if ( "`freq'" != "" ) {
                di as err "freq() is planned for a future release."
                clean_all 198
                exit 198
            }

            local 0, `store'
            syntax, [GENerate(str) genpre(str) MATrix(str) replace(str)]

            local 0, `freq'
            syntax, [GENerate(str) MATrix(str) replace(str)]

            * Check which exist (w/replace) and create empty vars
            * Pass to plugin call

            * store(matrix(name)) <- only numeric
            * store(data(varlist)) <- any type; must be same length as by vars
            * store(data prefix(prefix) [truncate]) <- prefix; must be valid stata names
            * freq(matrix(name))
            * freq(mata(name))
        }
        else if ( inlist("`gfunction'",  "top") ) {
            local 0, `gtop'
            syntax, ntop(real)    ///
                    pct(real)     ///
                    freq(real)    ///
                [                 ///
                    misslab(str)  ///
                    otherlab(str) ///
                    groupmiss     ///
                ]
            local gcall `gfunction'

            scalar __gtools_top_ntop      = `ntop'
            scalar __gtools_top_pct       = `pct'
            scalar __gtools_top_freq      = `freq'
            scalar __gtools_top_miss      = ( `"`misslab'"'   != "" )
            scalar __gtools_top_groupmiss = ( `"`groupmiss'"' != "" )
            scalar __gtools_top_other     = ( `"`otherlab'"'  != "" )
            scalar __gtools_top_lmiss     = length(`"`misslab'"')
            scalar __gtools_top_lother    = length(`"`otherlab'"')

            local nrows = abs(`ntop')               ///
                        + scalar(__gtools_top_miss) ///
                        + scalar(__gtools_top_other)

            cap noi check_matsize, nvars(`nrows')
            if ( _rc ) {
                local rc = _rc
                clean_all `rc'
                exit `rc'
            }

            cap noi check_matsize, nvars(`=scalar(__gtools_kvars_num)')
            if ( _rc ) {
                local rc = _rc
                clean_all `rc'
                exit `rc'
            }

            matrix __gtools_top_matrix = J(max(`nrows', 1), 5, 0)
            if ( `=scalar(__gtools_kvars_num)' > 0 ) {
                matrix __gtools_top_num = ///
                    J(max(`nrows', 1), `=scalar(__gtools_kvars_num)', .)
            }
        }
        else if ( inlist("`gfunction'",  "quantiles") ) {
            local 0 `gquantiles'
            syntax [name],                    ///
            [                                 ///
                xsources(varlist numeric)     ///
                                              ///
                Nquantiles(real 0)            ///
                                              ///
                Quantiles(numlist)            ///
                cutoffs(numlist)              ///
                                              ///
                quantmatrix(str)              ///
                cutmatrix(str)                ///
                                              ///
                Cutpoints(varname numeric)    ///
                cutquantiles(varname numeric) ///
                                              ///
                pctile(name)                  ///
                GENp(name)                    ///
                BINFREQvar(name)              ///
                replace                       ///
                                              ///
                returnlimit(real 1001)        ///
                dedup                         ///
                cutifin                       ///
                cutby                         ///
                _pctile                       ///
                binfreq                       ///
                method(int 0)                 ///
                XMISSing                      ///
                ALTdef                        ///
                strict                        ///
                minmax                        ///
            ]

            local gcall `gfunction'
            local xvars `namelist'     ///
                        `pctile'       ///
                        `binfreqvar'   ///
                        `genp'         ///
                        `cutpoints'    ///
                        `cutquantiles' ///
                        `xsources'

            ***************************
            *  quantiles and cutoffs  *
            ***************************

            * First we need to parse quantmatrix and cutmatrix to find
            * out how many quantiles or cutoffs we may have.

            if ( "`quantmatrix'" != "" ) {
                if ( "`quantiles'" != "" ) {
                    disp as err "Specify only one of quantiles() or quantmatrix()"
                    clean_all 198
                    exit 198
                }

                tempname m c r
                mata: `m' = st_matrix("`quantmatrix'")
                mata: `c' = cols(`m')
                mata: `r' = rows(`m')
                cap mata: assert(min((`c', `r')) == 1)
                if ( _rc ) {
                    disp as err "quantmatrix() must be a N by 1 or 1 by N matrix."
                    clean_all 198
                    exit 198
                }

                cap mata: assert(all(`m' :> 0) & all(`m' :< 100))
                if ( _rc ) {
                    disp as err "quantmatrix() must contain all values" ///
                                " strictly between 0 and 100"
                    clean_all 198
                    exit 198
                }
                mata: st_local("xhow_nq2", strofreal(max((`c', `r')) > 0))
                mata: st_matrix("__gtools_xtile_quantiles", rowshape(`m', 1))
                mata: st_numscalar("__gtools_xtile_nq2", max((`c', `r')))
            }
            else {
                local xhow_nq2 = ( `:list sizeof quantiles' > 0 )
                scalar __gtools_xtile_nq2 = `:list sizeof quantiles'
            }

            if ( "`cutmatrix'" != "" ) {
                if ( "`cutoffs'" != "" ) {
                    disp as err "Specify only one of cutoffs() or cutmatrix()"
                    clean_all 198
                    exit 198
                }

                tempname m c r
                mata: `m' = st_matrix("`cutmatrix'")
                mata: `c' = cols(`m')
                mata: `r' = rows(`m')
                cap mata: assert(min((`c', `r')) == 1)
                if ( _rc ) {
                    disp as err "cutmatrix() must be a N by 1 or 1 by N matrix."
                    clean_all 198
                    exit 198
                }
                mata: st_local("xhow_cuts", strofreal(max((`c', `r')) > 0))
                mata: st_matrix("__gtools_xtile_cutoffs", rowshape(`m', 1))
                mata: st_numscalar("__gtools_xtile_ncuts", max((`c', `r')))
            }
            else {
                local xhow_cuts = ( `:list sizeof cutoffs' > 0 )
                scalar __gtools_xtile_ncuts = `:list sizeof cutoffs'
            }

            ******************************
            *  Rest of quantile parsing  *
            ******************************

            * Make sure cutoffs/quantiles are correctly requested (can
            * only specify 1 method!)

            local xhow_nq      = ( `nquantiles' > 0 )
            local xhow_cutvars = ( `:list sizeof cutpoints'    > 0 )
            local xhow_qvars   = ( `:list sizeof cutquantiles' > 0 )
            local xhow_total   = `xhow_nq'      ///
                               + `xhow_nq2'     ///
                               + `xhow_cuts'    ///
                               + `xhow_cutvars' ///
                               + `xhow_qvars'

            local early_rc = 0
            if ( "`_pctile'" != "" ) {
                if ( `nquantiles' > `returnlimit' ) {
                    di as txt "Warning: {opt nquantiles()} > returnlimit"     ///
                              " (`nquantiles' > `returnlimit')."              ///
                        _n(1) "Will not store return values beyond"           ///
                              " `returnlimit'. Try {opt pctile()}"            ///
                        _n(1) "(Note: you can also pass {opt returnlimit(.)}" ///
                              " but that is very slow.)"
                }

                if ( `:list sizeof quantiles' > `returnlimit' ) {
                    di as txt "Warning: # quantiles in"                       ///
                              " {opt quantiles()} > returnlimit"              ///
                              " (`:list sizeof quantiles' > `returnlimit')."  ///
                        _n(1) "Will not store return values beyond"           ///
                              " `returnlimit'. Try {opt pctile()}"            ///
                        _n(1) "(Note: you can also pass {opt returnlimit(.)}" ///
                              " but that is very slow.)"
                }

                if ( `:list sizeof cutoffs' > `returnlimit' ) {
                    di as txt "Warning: # of cutoffs in"                      ///
                              " {opt cutoffs()} > returnlimit"                ///
                              " (`:list sizeof cutoffs' > `returnlimit')."    ///
                        _n(1) "Will not store return values beyond"           ///
                              " `returnlimit'. Try {opt pctile()}"            ///
                        _n(1) "(Note: you can also pass {opt returnlimit(.)}" ///
                              " but that is very slow.)"
                }
            }

            if ( `xhow_total' == 0 ) {
                local nquantiles = 2
            }
            else if (`xhow_total' > 1) {
                if (  `nquantiles'    >  0  ) local olist "`olist' nquantiles()"
                if ( "`quantiles'"    != "" ) local olist "`olist', quantiles()"
                if ( "`quantmatrix'"  != "" ) local olist "`olist', quantmatrix()"
                if ( "`cutpoints'"    != "" ) local olist "`olist', cutpoints()"
                if ( "`cutmatrix'"    != "" ) local olist "`olist', cutmatrix()"
                if ( "`cutquantiles'" != "" ) local olist "`olist', cutquantiles()"
                if ( "`cutoffs'"      != "" ) local olist "`olist', cutoffs()"
                di as err "Specify only one of: `olist'"
                local early_rc = 198
            }

            if ( `xhow_nq' & (`nquantiles' < 2) ) {
                di as err "{opt nquantiles()} must be greater than or equal to 2"
                local early_rc = 198
            }

            foreach quant of local quantiles {
                if ( `quant' < 0 ) | ( `quant' > 100 ) {
                    di as err "{opt quantiles()} must all be strictly" ///
                              " between 0 and 100"
                    local early_rc = 198
                }
                if ( `quant' == 0 ) | ( `quant' == 100 ) {
                    di as err "{opt quantiles()} cannot be 0 or 100" ///
                              " (note: try passing option {opt minmax})"
                    local early_rc = 198
                }
            }

            local xgen_ix  = ( "`namelist'"   != "" )
            local xgen_p   = ( "`pctile'"     != "" )
            local xgen_gp  = ( "`genp'"       != "" )
            local xgen_bf  = ( "`binfreqvar'" != "" )
            local xgen_tot = `xgen_p' + `xgen_gp' + `xgen_bf'

            local xgen_required = `xhow_cutvars' + `xhow_qvars'
            local xgen_any      = `xgen_ix' | `xgen_p' | `xgen_gp' | `xgen_bf'
            if ( (`xgen_required' > 0) & !(`xgen_any') ) {
                if ( "`cutpoints'"    != "" ) local olist "cutpoints()"
                if ( "`cutquantiles'" != "" ) local olist "cutquantiles()"
                di as err "Option {opt `olist'} requires xtile or pctile"
                local early_rc = 198
            }

            local xbin_any = ("`binfreq'" != "") & ("`binfreqvar'" == "")
            if ( (`xgen_required' > 0) & `xbin_any' ) {
                if ( "`cutpoints'"    != "" ) local olist "cutpoints()"
                if ( "`cutquantiles'" != "" ) local olist "cutquantiles()"
                di as err "{opt binfreq} not allowed with {opt `olist'};" ///
                          " try {opth binfreq(newvarname)}"
                local early_rc = 198
            }

            if ( ("`cutoffs'" != "") & ("`binfreq'" == "") & !(`xgen_any') ) {
                di as err "Nothing to do: Option {opt cutoffs()} requires" ///
                          " {opt binfreq}, {opt xtile}, or {opt pctile}"
                local early_rc = 198
            }

            local xgen_maxdata = `xgen_p' | `xgen_gp' | `xgen_bf'
            if ( (`nquantiles' > `=_N + 1') & `xgen_maxdata' ) {
                di as err "{opt nquantiles()} must be less than or equal to" ///
                          " `=_N +1' (# obs + 1) with {opt pctile()} or {opt binfreq()}"
                local early_rc = 198
            }

            if ( (`=scalar(__gtools_xtile_nq2)' > `=_N') & `xgen_maxdata' ) {
                di as err "Number of {opt quantiles()} must be"  ///
                          " less than or equal to `=_N' (# obs)" ///
                          " with options {opt pctile()} or {opt binfreq()}"
                local early_rc = 198
            }

            if ( (`=scalar(__gtools_xtile_ncuts)' > `=_N') & `xgen_maxdata' ) {
                di as err "Number of {opt cutoffs()} must be "   ///
                          " less than or equal to `=_N' (# obs)" ///
                          " with options {opt pctile()} or {opt binfreq()}"
                local early_rc = 198
            }

            if ( `early_rc' ) {
                clean_all `early_rc'
                exit `early_rc'
            }

            scalar __gtools_xtile_xvars    = `:list sizeof xsources'

            scalar __gtools_xtile_nq       = `nquantiles'
            scalar __gtools_xtile_cutvars  = `:list sizeof cutpoints'
            scalar __gtools_xtile_qvars    = `:list sizeof cutquantiles'

            scalar __gtools_xtile_gen      = `xgen_ix'
            scalar __gtools_xtile_pctile   = `xgen_p'
            scalar __gtools_xtile_genpct   = `xgen_gp'
            scalar __gtools_xtile_pctpct   = `xgen_bf'

            scalar __gtools_xtile_altdef   = ( "`altdef'"   != "" )
            scalar __gtools_xtile_missing  = ( "`xmissing'" != "" )
            scalar __gtools_xtile_strict   = ( "`strict'"   != "" )
            scalar __gtools_xtile_min      = ( "`minmax'"   != "" )
            scalar __gtools_xtile_max      = ( "`minmax'"   != "" )
            scalar __gtools_xtile_method   = `method'
            scalar __gtools_xtile_bincount = ( "`binfreq'" != "" )
            scalar __gtools_xtile__pctile  = ( "`_pctile'" != "" )
            scalar __gtools_xtile_dedup    = ( "`dedup'"   != "" )
            scalar __gtools_xtile_cutifin  = ( "`cutifin'" != "" )
            scalar __gtools_xtile_cutby    = ( "`cutby'"   != "" )

            cap noi check_matsize, nvars(`=scalar(__gtools_xtile_nq2)')
            if ( _rc ) {
                local rc = _rc
                di as err _n(1) "Note: bypass matsize and specify quantiles" ///
                                " using a variable via {opt cutquantiles()}"
                clean_all `rc'
                exit `rc'
            }

            cap noi check_matsize, nvars(`=scalar(__gtools_xtile_ncuts)')
            if ( _rc ) {
                local rc = _rc
                di as err _n(1) "Note: bypass matsize and specify cutoffs" ///
                                " using a variable via {opt cutpoints()}"
                clean_all `rc'
                exit `rc'
            }

            * I don't think it's possible to preserve numerical precision
            * with numlist. And I asked...
            *
            * https://stackoverflow.com/questions/47336278
            * https://www.statalist.org/forums/forum/general-stata-discussion/general/1418513
            *
            * Hance I should have added other ways to request quantiles:
            *
            *     - cutquantiles
            *     - quantmatrix
            *
            * and other ways to request cut points:
            *
            *     - cutoffs
            *     - cutmatrix

            scalar __gtools_xtile_imprecise = 0
            matrix __gtools_xtile_quantbin  = ///
                J(1, cond(`xhow_nq2',  `=scalar(__gtools_xtile_nq2)',   1), 0)
            matrix __gtools_xtile_cutbin    = ///
                J(1, cond(`xhow_cuts', `=scalar(__gtools_xtile_ncuts)', 1), 0)

            if ( `xhow_nq2' & ("`quantiles'" != "") & ("`quantmatrix'" == "") ) {
                matrix __gtools_xtile_quantiles = ///
                    J(1, cond(`xhow_nq2',  `=scalar(__gtools_xtile_nq2)',   1), 0)

                local k = 0
                foreach quant of numlist `quantiles' {
                    local ++k
                    matrix __gtools_xtile_quantiles[1, `k'] = `quant'
                    if ( strpos("`quant'", ".") & (length("`quant'") >= 13) & ("`altdef'" == "") ) {
                        scalar __gtools_xtile_imprecise = 1
                    }
                }
                if ( `=scalar(__gtools_xtile_imprecise)' ) {
                    disp as err "Warning: Loss of numerical precision"    ///
                                " with option {opth quantiles(numlist)}." ///
                          _n(1) "Stata's numlist truncates decimals with" ///
                                " more than 13 significant digits."       ///
                          _n(1) "Consider using {cmd:altdef} or "         ///
                                " {opth quantmatrix(name)}."
                }
            }

            if ( `xhow_cuts'  & ("`cutoffs'" != "") & ("`cutmatrix'" == "") ) {
                matrix __gtools_xtile_cutoffs = ///
                    J(1, cond(`xhow_cuts', `=scalar(__gtools_xtile_ncuts)', 1), 0)

                local k = 0
                foreach cut of numlist `cutoffs' {
                    local ++k
                    matrix __gtools_xtile_cutoffs[1, `k'] = `cut'
                    if ( strpos("`cut'", ".") & (length("`cut'") >= 13) ) {
                        scalar __gtools_xtile_imprecise = 1
                    }
                }
                if ( `=scalar(__gtools_xtile_imprecise)' ) {
                    disp as err "Warning: Loss of numerical precision"    ///
                                " with option {opth cutoffs(numlist)}."   ///
                          _n(1) "Stata's numlist truncates decimals with" ///
                                " more than 13 significant digits."       ///
                          _n(1) "Consider using {cmd:altdef} or "         ///
                                " {opth cutmatrix(name)}."
                }
            }

            local xbin_any = ("`binfreq'" != "") & ("`binfreqvar'" == "")
            if ( (`nquantiles' > 0) & `xbin_any' ) {
                cap noi check_matsize, nvars(`=`nquantiles' - 1')
                if ( _rc ) {
                    local rc = _rc
                    di as err _n(1) "Note: You can bypass matsize and" ///
                                    " save binfreq to a variable via binfreq()"
                    clean_all `rc'
                    exit `rc'
                }
                matrix __gtools_xtile_quantbin = ///
                    J(1, max(`=scalar(__gtools_xtile_nq2)', `nquantiles' - 1), 0)
                local __gtools_xtile_nq_extra bin
            }

            if ( (`nquantiles' > 0) & ("`_pctile'" != "") ) {
                cap noi check_matsize, nvars(`=`nquantiles' - 1')
                if ( _rc ) {
                    local rc = _rc
                    di as err _n(1) "Note: You can bypass matsize and" ///
                                    " save quantiles to a variable via pctile()"
                    clean_all `rc'
                    exit `rc'
                }
                matrix __gtools_xtile_quantiles = ///
                    J(1, max(`=scalar(__gtools_xtile_nq2)', `nquantiles' - 1), 0)
                local __gtools_xtile_nq_extra `__gtools_xtile_nq_extra' quantiles
            }

            scalar __gtools_xtile_size = `nquantiles'
            scalar __gtools_xtile_size = ///
                max(__gtools_xtile_size, __gtools_xtile_nq2 + 1)
            scalar __gtools_xtile_size = ///
                max(__gtools_xtile_size, __gtools_xtile_ncuts + 1)
            scalar __gtools_xtile_size = ///
                max(__gtools_xtile_size, cond(__gtools_xtile_cutvars, `=_N+1', 1))
            scalar __gtools_xtile_size = ///
                max(__gtools_xtile_size, cond(__gtools_xtile_qvars,   `=_N+1', 1))

            local toadd 0
            qui mata: __gtools_xtile_addlab = J(1, 0, "")
            qui mata: __gtools_xtile_addnam = J(1, 0, "")
            foreach xgen in xgen_ix xgen_p xgen_gp xgen_bf {
                if ( ``xgen'' > 0 ) {
                    if ( "`xgen'" == "xgen_ix" ) {
                        if ( `=scalar(__gtools_xtile_size)' < maxbyte() ) {
                            local qtype byte
                        }
                        else if ( `=scalar(__gtools_xtile_size)' < maxint() ) {
                            local qtype int
                        }
                        else if ( `=scalar(__gtools_xtile_size)' < maxlong() ) {
                            local qtype long
                        }
                        else local qtype double
                        local qvar `namelist'
                    }
                    else {
                        if ( "`:type `xsources''" == "double" ) local qtype double
                        else local qtype: set type

                        if ( "`xgen'" == "xgen_p"  ) local qvar `pctile'
                        if ( "`xgen'" == "xgen_gp" ) local qvar `genp'
                        if ( "`xgen'" == "xgen_bf" ) {
                            if ( `=_N' < maxbyte() ) {
                                local qtype byte
                            }
                            else if ( `=_N' < maxint() ) {
                                local qtype int
                            }
                            else if ( `=_N' < maxlong() ) {
                                local qtype long
                            }
                            else local qtype double
                            local qvar `binfreqvar'
                        }
                    }
                    cap confirm new var `qvar'
                    if ( _rc & ("`replace'" == "") ) {
                        di as err "Variable `qvar' exists with no replace."
                        clean_all 198
                        exit 198
                    }
                    else if ( _rc & ("`replace'" != "") ) {
                        qui replace `qvar' = .
                    }
                    else if ( _rc == 0 ) {
                        local ++toadd
                        mata: __gtools_xtile_addlab = __gtools_xtile_addlab, "`qtype'"
                        mata: __gtools_xtile_addnam = __gtools_xtile_addnam, "`qvar'"
                    }
                }
            }

            if ( `toadd' > 0 ) {
                qui mata: st_addvar(__gtools_xtile_addlab, __gtools_xtile_addnam)
            }

            local msg "Parsed quantiles and added targets"
            gtools_timer info 98 `"`msg'"', prints(`benchmark')
        }
        else local gcall `gfunction'

        local plugvars `byvars' `etargets' `extravars' `contractvars' `xvars'
        cap noi plugin call gtools_plugin `plugvars' `ifin', `gcall'
        local rc = _rc
        cap noi rc_dispatch `byvars', rc(`=_rc') `opts'
        if ( _rc ) {
            local rc = _rc
            clean_all `rc'
            exit `rc'
        }

        local msg "Plugin runtime"
        gtools_timer info 98 `"`msg'"', prints(`benchmark') off
    }

    local msg "Total runtime`runtxt'"
    gtools_timer info 99 `"`msg'"', prints(`benchmark') off

    * Return values
    * -------------

    * generic
    if ( `rset' ) {
        return scalar N     = `r_N'
        return scalar J     = `r_J'
        return scalar minJ  = `r_minJ'
        return scalar maxJ  = `r_maxJ'
    }

    return scalar kvar  = `=scalar(__gtools_kvars)'
    return scalar knum  = `=scalar(__gtools_kvars_num)'
    return scalar kint  = `=scalar(__gtools_kvars_int)'
    return scalar kstr  = `=scalar(__gtools_kvars_str)'

    return local byvars = "`byvars'"
    return local bynum  = "`bynum'"
    return local bystr  = "`bystr'"

    * levelsof
    if ( inlist("`gfunction'", "levelsof", "top") & `=scalar(__gtools_levels_return)' ) {
        return local levels `"`vals'"'
        return local sep    `"`sep'"'
        return local colsep `"`colsep'"'
    }

    * top matrix
    if ( inlist("`gfunction'", "top") ) {
        return matrix toplevels = __gtools_top_matrix
        return matrix numlevels = __gtools_top_num
    }

    * quantile info
    if ( inlist("`gfunction'", "quantiles") ) {
        return local  quantiles    = "`quantiles'"
        return local  cutoffs      = "`cutoffs'"
        return local  nqextra      = "`__gtools_xtile_nq_extra'"
        return local  Nxvars       = scalar(__gtools_xtile_xvars)

        return scalar min          = scalar(__gtools_xtile_min)
        return scalar max          = scalar(__gtools_xtile_max)
        return scalar method_ratio = scalar(__gtools_xtile_method)
        return scalar imprecise    = scalar(__gtools_xtile_imprecise)

        return scalar nquantiles   = scalar(__gtools_xtile_nq)
        return scalar nquantiles2  = scalar(__gtools_xtile_nq2)
        return scalar ncutpoints   = scalar(__gtools_xtile_cutvars)
        return scalar ncutoffs     = scalar(__gtools_xtile_ncuts)
        return scalar nquantpoints = scalar(__gtools_xtile_qvars)

        return matrix quantiles_used     = __gtools_xtile_quantiles
        return matrix quantiles_bincount = __gtools_xtile_quantbin
        return matrix cutoffs_used       = __gtools_xtile_cutoffs
        return matrix cutoffs_bincount   = __gtools_xtile_cutbin
    }

    return matrix invert = __gtools_invert
    clean_all 0
    exit 0
end

***********************************************************************
*                              hashsort                               *
***********************************************************************

capture program drop hashsort_inner
program hashsort_inner, sortpreserve
    syntax varlist [in], benchmark(int) [invertinmata]
    cap noi plugin call gtools_plugin `varlist' `_sortindex' `in', hashsort
    if ( _rc ) {
        local rc = _rc
        clean_all `rc'
        exit `rc'
    }
    if ( "`invertinmata'" != "" ) {
        mata: st_store(., "`_sortindex'", invorder(st_data(., "`_sortindex'")))
    }
    * else {
    *     mata: st_store(., "`_sortindex'", st_data(., "`_sortindex'"))
    * }

    c_local r_N    = `r_N'
    c_local r_J    = `r_J'
    c_local r_minJ = `r_minJ'
    c_local r_maxJ = `r_maxJ'

    local msg "Plugin runtime"
    gtools_timer info 98 `"`msg'"', prints(`benchmark')
end

***********************************************************************
*                               Cleanup                               *
***********************************************************************

capture program drop clean_all
program clean_all
    args rc
    if ( "`rc'" == "" ) local rc = 0

    set varabbrev ${GTOOLS_USER_INTERNAL_VARABBREV}
    global GTOOLS_USER_INTERNAL_VARABBREV

    cap scalar drop __gtools_init_targ
    cap scalar drop __gtools_any_if
    cap scalar drop __gtools_verbose
    cap scalar drop __gtools_debug
    cap scalar drop __gtools_benchmark
    cap scalar drop __gtools_countonly
    cap scalar drop __gtools_seecount
    cap matrix drop __gtools_unsorted
    cap scalar drop __gtools_nomiss
    cap scalar drop __gtools_missing
    cap scalar drop __gtools_hash
    cap scalar drop __gtools_encode
    cap scalar drop __gtools_replace
    cap scalar drop __gtools_countmiss
    cap scalar drop __gtools_skipcheck

    cap scalar drop __gtools_top_ntop
    cap scalar drop __gtools_top_pct
    cap scalar drop __gtools_top_freq
    cap scalar drop __gtools_top_miss
    cap scalar drop __gtools_top_groupmiss
    cap scalar drop __gtools_top_other
    cap scalar drop __gtools_top_lmiss
    cap scalar drop __gtools_top_lother
    cap matrix drop __gtools_top_matrix
    cap matrix drop __gtools_top_num
    cap matrix drop __gtools_contract_which

    cap scalar drop __gtools_levels_return

    cap scalar drop __gtools_xtile_xvars
    cap scalar drop __gtools_xtile_nq
    cap scalar drop __gtools_xtile_nq2
    cap scalar drop __gtools_xtile_cutvars
    cap scalar drop __gtools_xtile_ncuts
    cap scalar drop __gtools_xtile_qvars
    cap scalar drop __gtools_xtile_gen
    cap scalar drop __gtools_xtile_pctile
    cap scalar drop __gtools_xtile_genpct
    cap scalar drop __gtools_xtile_pctpct
    cap scalar drop __gtools_xtile_altdef
    cap scalar drop __gtools_xtile_missing
    cap scalar drop __gtools_xtile_strict
    cap scalar drop __gtools_xtile_min
    cap scalar drop __gtools_xtile_max
    cap scalar drop __gtools_xtile_method
    cap scalar drop __gtools_xtile_bincount
    cap scalar drop __gtools_xtile__pctile
    cap scalar drop __gtools_xtile_dedup
    cap scalar drop __gtools_xtile_cutifin
    cap scalar drop __gtools_xtile_cutby
    cap scalar drop __gtools_xtile_imprecise
    cap matrix drop __gtools_xtile_quantiles
    cap matrix drop __gtools_xtile_cutoffs
    cap matrix drop __gtools_xtile_quantbin
    cap matrix drop __gtools_xtile_cutbin
    cap scalar drop __gtools_xtile_size

    cap scalar drop __gtools_kvars
    cap scalar drop __gtools_kvars_num
    cap scalar drop __gtools_kvars_int
    cap scalar drop __gtools_kvars_str

    cap scalar drop __gtools_group_data
    cap scalar drop __gtools_group_fill
    cap scalar drop __gtools_group_val

    cap scalar drop __gtools_cleanstr
    cap scalar drop __gtools_sep_len
    cap scalar drop __gtools_colsep_len
    cap scalar drop __gtools_numfmt_len
    cap scalar drop __gtools_numfmt_max

    cap scalar drop __gtools_k_vars
    cap scalar drop __gtools_k_targets
    cap scalar drop __gtools_k_stats
    cap scalar drop __gtools_k_group

    cap scalar drop __gtools_st_time
    cap scalar drop __gtools_used_io
    cap scalar drop __gtools_ixfinish
    cap scalar drop __gtools_J

    cap matrix drop __gtools_invert
    cap matrix drop __gtools_bylens
    cap matrix drop __gtools_numpos
    cap matrix drop __gtools_strpos

    cap matrix drop __gtools_group_targets
    cap matrix drop __gtools_group_init

    cap matrix drop __gtools_stats
    cap matrix drop __gtools_pos_targets

    * NOTE(mauricio): You had the urge to make sure you were dropping
    * variables at one point. Don't. This is file for gquantiles but not so
    * with gegen or gcollapse.  In the case of gcollapse, if the user ran w/o
    * fast then they were willing to leave the data in a bad stata in case
    * there was an error. In the casae of gegen, the main variable is a dummy
    * that is renamed later on.

    if ( `rc' ) {
        cap mata: st_dropvar(__gtools_xtile_addnam)
        * cap mata: st_dropvar(__gtools_togen_names[__gtools_togen_s])
        * cap mata: st_dropvar(__gtools_gc_addvars)
    }

    cap mata: mata drop __gtools_togen_k
    cap mata: mata drop __gtools_togen_s

    cap mata: mata drop __gtools_togen_types
    cap mata: mata drop __gtools_togen_names

    cap mata: mata drop __gtools_xtile_addlab
    cap mata: mata drop __gtools_xtile_addnam

    cap timer off   99
    cap timer clear 99

    cap timer off   98
    cap timer clear 98
end

***********************************************************************
*                           Parse by types                            *
***********************************************************************

capture program drop parse_by_types
program parse_by_types, rclass
    syntax [anything] [if] [in], [clean_anything(str)]

    if ( "`anything'" == "" ) {
        matrix __gtools_invert = 0
        matrix __gtools_bylens = 0

        return local invert  = 0
        return local varlist = ""
        return local varnum  = ""
        return local varstr  = ""

        scalar __gtools_kvars     = 0
        scalar __gtools_kvars_int = 0
        scalar __gtools_kvars_num = 0
        scalar __gtools_kvars_str = 0

        exit 0
    }

    cap matrix drop __gtools_invert
    cap matrix drop __gtools_bylens

    * Parse whether to invert sort order
    * ----------------------------------

    local parse    `anything'
    local varlist  ""
    local skip   = 0
    local invert = 0
    if strpos("`anything'", "-") {
        while ( trim("`parse'") != "" ) {
            gettoken var parse: parse, p(" -+")
            if inlist("`var'", "-", "+") {
                local skip   = 1
                local invert = ( "`var'" == "-" )
            }
            else {
                cap ds `var'
                if ( _rc ) {
                    local rc = _rc
                    di as err "Variable '`var'' does not exist."
                    di as err "Syntas: [+|-]varname [[+|-]varname ...]"
                    clean_all
                    exit `rc'
                }
                if ( `skip' ) {
                    local skip = 0
                    foreach var in `r(varlist)' {
                        matrix __gtools_invert = nullmat(__gtools_invert), ///
                                                 `invert'
                    }
                }
                else {
                    foreach var in `r(varlist)' {
                        matrix __gtools_invert = nullmat(__gtools_invert), 0
                    }
                }
                local varlist `varlist' `r(varlist)'
            }
        }
    }
    else {
        local varlist `clean_anything'
        matrix __gtools_invert = J(1, max(`:list sizeof varlist', 1), 0)
    }

    * Check how many of each variable type we have
    * --------------------------------------------

    local kint  = 0
    local knum  = 0
    local kstr  = 0
    local kvars = 0

    local varint ""
    local varnum ""
    local varstr ""

    if ( "`varlist'" != "" ) {
        cap confirm variable `varlist'
        if ( _rc ) {
            di as err "{opt varlist} requried but received: `varlist'"
            exit 198
        }

        foreach byvar of varlist `varlist' {
            local ++kvars
            if inlist("`:type `byvar''", "byte", "int", "long") {
                local ++kint
                local ++knum
                local varint `varint' `byvar'
                local varnum `varnum' `byvar'
                matrix __gtools_bylens = nullmat(__gtools_bylens), 0
            }
            else if inlist("`:type `byvar''", "float", "double") {
                local ++knum
                local varnum `varnum' `byvar'
                matrix __gtools_bylens = nullmat(__gtools_bylens), 0
            }
            else {
                local ++kstr
                local varstr `varstr' `byvar'
                if regexm("`:type `byvar''", "str([1-9][0-9]*|L)") {
                    if (regexs(1) == "L") {
                        tempvar strlen
                        gen long `strlen' = length(`byvar')
                        qui sum `strlen', meanonly
                        matrix __gtools_bylens = nullmat(__gtools_bylens), ///
                                                 `r(max)'
                    }
                    else {
                        matrix __gtools_bylens = nullmat(__gtools_bylens), ///
                                                 `:di regexs(1)'
                    }
                }
                else {
                    di as err "variable `byvar' has unknown type" ///
                              " '`:type `byvar'''"
                    exit 198
                }
            }
        }

        cap assert `kvars' == `:list sizeof varlist'
        if ( _rc ) {
            di as err "Error parsing syntax call; variable list was:" ///
                _n(1) "`anything'"
            exit 198
        }
    }

    * Parse which hashing strategy to use
    * -----------------------------------

    scalar __gtools_kvars     = `kvars'
    scalar __gtools_kvars_int = `kint'
    scalar __gtools_kvars_num = `knum'
    scalar __gtools_kvars_str = `kstr'

    * Return hash info
    * ----------------

    return local invert     = `invert'
    return local varlist    = "`varlist'"
    return local varnum     = "`varnum'"
    return local varstr     = "`varstr'"
end

***********************************************************************
*                        Generic hash helpers                         *
***********************************************************************

capture program drop confirm_var
program confirm_var, rclass
    syntax anything, [replace]
    local newvar = 1
    if ( "`replace'" != "" ) {
        cap confirm new variable `anything'
        if ( _rc ) {
            local newvar = 0
        }
        else {
            cap noi confirm name `anything'
            if ( _rc ) {
                local rc = _rc
                clean_all
                exit `rc'
            }
        }
    }
    else {
        cap confirm new variable `anything'
        if ( _rc ) {
            local rc = _rc
            clean_all
            cap noi confirm name `anything'
            if ( _rc ) {
                exit `rc'
            }
            else {
                di as err "Variable `anything' exists;" ///
                          " try a different name or run with -replace-"
                exit `rc'
            }
        }
    }
    return scalar newvar = `newvar'
    exit 0
end

capture program drop rc_dispatch
program rc_dispatch
    syntax [varlist], rc(int) oncollision(str)

    local website_url  https://github.com/mcaceresb/stata-gtools/issues
    local website_disp github.com/mcaceresb/stata-gtools

    if ( `rc' == 17000 ) {
        di as err "There may be 128-bit hash collisions!"
        di as err `"This is a bug. Please report to"' ///
                  `" {browse "`website_url'":`website_disp'}"'
        if ( "`oncollision'" == "fallback" ) {
            exit 17999
        }
        else {
            exit 17000
        }
    }
    else if ( `rc' == 17001 ) {
        di as txt "(no observations)"
        exit 17001
    }
    else if ( `rc' == 459 ) {
		local kvars : word count `varlist'
        local s = cond(`kvars' == 1, "", "s")
        di as err "variable`s' `varlist' should never be missing"
        exit 459
    }
    else if ( `rc' == 17459 ) {
		local kvars : word count `varlist'
		local var  = cond(`kvars'==1, "variable", "variables")
		local does = cond(`kvars'==1, "does", "do")
		di as err "`var' `varlist' `does' not uniquely" ///
                  " identify the observations"
        exit 459
    }
    else {
        * error `rc'
        exit `rc'
    }
end

capture program drop gtools_timer
program gtools_timer, rclass
    syntax anything, [prints(int 0) end off]
    tokenize `"`anything'"'
    local what  `1'
    local timer `2'
    local msg   `"`3'; "'

    if ( inlist("`what'", "start", "on") ) {
        cap timer off `timer'
        cap timer clear `timer'
        timer on `timer'
    }
    else if ( inlist("`what'", "info") ) {
        timer off `timer'
        qui timer list
        return scalar t`timer' = `r(t`timer')'
        return local pretty`timer' = trim("`:di %21.4gc r(t`timer')'")
        if ( `prints' ) di `"`msg'`:di trim("`:di %21.4gc r(t`timer')'")' seconds"'
        timer off `timer'
        timer clear `timer'
        timer on `timer'
    }

    if ( "`end'`off'" != "" ) {
        timer off `timer'
        timer clear `timer'
    }
end

capture program drop check_matsize
program check_matsize
    syntax [anything], [nvars(int 0)]
    if ( `nvars' == 0 ) local nvars `:list sizeof anything'
    if ( `nvars' > `c(matsize)' ) {
        cap set matsize `=`nvars''
        if ( _rc ) {
            di as err                                                        ///
                _n(1) "{bf:# variables > matsize (`nvars' > `c(matsize)').}" ///
                _n(2) "    {stata set matsize `=`nvars''}"                   ///
                _n(2) "{bf:failed. Try setting matsize manually.}"
            exit 908
        }
    }
end

capture program drop parse_targets
program parse_targets
    syntax, sources(str) targets(str) stats(str) [replace k_exist(str)]
    local k_vars    = `:list sizeof sources'
    local k_targets = `:list sizeof targets'
    local k_stats   = `:list sizeof stats'

    local uniq_sources: list uniq sources
    local uniq_targets: list uniq targets

    cap assert `k_targets' == `k_stats'
    if ( _rc ) {
        di as err " `k_targets' target(s) require(s) `k_targets' stat(s)," ///
                  " but user passed `k_stats'"
        exit 198
    }

    if ( `k_targets' > 1 ) {
        cap assert `k_targets' == `k_vars'
        if ( _rc ) {
            di as err " `k_targets' targets require `k_targets' sources," ///
                      " but user passed `k_vars'"
            exit 198
        }
    }
    else if ( `k_targets' == 1 ) {
        cap assert `k_vars' > 0
        if ( _rc ) {
            di as err "Specify at least one source variable"
            exit 198
        }
        cap assert `:list sizeof uniq_sources' == `k_vars'
        if ( _rc ) {
            di as txt "(warning: repeat sources ignored with 1 target)"
        }
    }
    else {
        di as err "Specify at least one target"
        exit 198
    }

    local stats: subinstr local stats "total" "sum", all
    local allowed sum        ///
                  mean       ///
                  sd         ///
                  max        ///
                  min        ///
                  count      ///
                  median     ///
                  iqr        ///
                  percent    ///
                  first      ///
                  last       ///
                  firstnm    ///
                  lastnm     ///
                  freq       ///
                  semean     ///
                  sebinomial ///
                  sepoisson

    cap assert `:list sizeof uniq_targets' == `k_targets'
    if ( _rc ) {
        di as err "Cannot specify multiple targets with the same name."
        exit 198
    }

    if ( "`k_exist'" != "targets" ) {
        foreach var of local uniq_sources {
            cap confirm variable `var'
            if ( _rc ) {
                di as err "Source `var' has to exist."
                exit 198
            }

            cap confirm numeric variable `var'
            if ( _rc ) {
                di as err "Source `var' must be numeric."
                exit 198
            }
        }
    }

    mata: __gtools_stats       = J(1, `k_stats',   .)
    mata: __gtools_pos_targets = J(1, `k_targets', 0)

    cap noi check_matsize `targets'
    if ( _rc ) exit _rc

    forvalues k = 1 / `k_targets' {
        local src: word `k' of `sources'
        local trg: word `k' of `targets'
        local st:  word `k' of `stats'

        if ( `:list st in allowed' ) {
            encode_stat `st'
            mata: __gtools_stats[`k'] = `r(statcode)'
        }
        else if regexm("`st'", "^p([0-9][0-9]?(\.[0-9]+)?)$") {
            if ( `:di regexs(1)' == 0 ) {
                di as error "Invalid stat: (`st'; maybe you meant 'min'?)"
                exit 110
            }
            mata: __gtools_stats[`k'] = `:di regexs(1)'
        }
        else if ( "`st'" == "p100" ) {
            di as error "Invalid stat: (`st'; maybe you meant 'max'?)"
            exit 110
        }
        else {
            di as error "Invalid stat: `st'"
            exit 110
        }

        if ( "`k_exist'" != "sources" ) {
            cap confirm variable `trg'
            if ( _rc ) {
                di as err "Target `trg' has to exist."
                exit 198
            }

            cap confirm numeric variable `trg'
            if ( _rc ) {
                di as err "Target `trg' must be numeric."
                exit 198
            }
        }

        mata: __gtools_pos_targets[`k'] = `:list posof `"`src'"' in uniq_sources' - 1
    }

    scalar __gtools_k_vars    = `:list sizeof uniq_sources'
    scalar __gtools_k_targets = `k_targets'
    scalar __gtools_k_stats   = `k_stats'

    c_local __gtools_sources `uniq_sources'
    c_local __gtools_targets `targets'

    mata: st_matrix("__gtools_stats",       __gtools_stats)
    mata: st_matrix("__gtools_pos_targets", __gtools_pos_targets)

    cap mata: mata drop __gtools_stats
    cap mata: mata drop __gtools_pos_targets
end

capture program drop encode_stat
program encode_stat, rclass
    if ( "`0'" == "sum"         ) local statcode -1
    if ( "`0'" == "mean"        ) local statcode -2
    if ( "`0'" == "sd"          ) local statcode -3
    if ( "`0'" == "max"         ) local statcode -4
    if ( "`0'" == "min"         ) local statcode -5
    if ( "`0'" == "count"       ) local statcode -6
    if ( "`0'" == "percent"     ) local statcode -7
    if ( "`0'" == "median"      ) local statcode 50
    if ( "`0'" == "iqr"         ) local statcode -9
    if ( "`0'" == "first"       ) local statcode -10
    if ( "`0'" == "firstnm"     ) local statcode -11
    if ( "`0'" == "last"        ) local statcode -12
    if ( "`0'" == "lastnm"      ) local statcode -13
    if ( "`0'" == "freq"        ) local statcode -14
    if ( "`0'" == "semean"      ) local statcode -15
    if ( "`0'" == "sebinomial"  ) local statcode -16
    if ( "`0'" == "sepoisson"   ) local statcode -17
    return scalar statcode = `statcode'
end

***********************************************************************
*                             Load plugin                             *
***********************************************************************

if ( inlist("`c(os)'", "MacOSX") | strpos("`c(machine_type)'", "Mac") ) local c_os_ macosx
else local c_os_: di lower("`c(os)'")

cap program drop env_set
program env_set, plugin using("env_set_`c_os_'.plugin")

* Windows hack
if ( "`c_os_'" == "windows" ) {
    cap confirm file spookyhash.dll
    if ( _rc ) {
        cap findfile spookyhash.dll
        if ( _rc ) {
            local rc = _rc
            local url https://raw.githubusercontent.com/mcaceresb/stata-gtools
            local url `url'/master/spookyhash.dll
            di as err `"gtools: `hashlib' not found."' _n(1)     ///
                      `"gtools: download {browse "`url'":here}"' ///
                      `" or run {opt gtools, dependencies}"'
            exit `rc'
        }
        mata: __gtools_hashpath = ""
        mata: __gtools_dll = ""
        mata: pathsplit(`"`r(fn)'"', __gtools_hashpath, __gtools_dll)
        mata: st_local("__gtools_hashpath", __gtools_hashpath)
        mata: mata drop __gtools_hashpath
        mata: mata drop __gtools_dll
        local path: env PATH
        if inlist(substr(`"`path'"', length(`"`path'"'), 1), ";") {
            mata: st_local("path", substr(`"`path'"', 1, `:length local path' - 1))
        }
        local __gtools_hashpath: subinstr local __gtools_hashpath "/" "\", all
        local newpath `"`path';`__gtools_hashpath'"'
        local truncate 2048
        if ( `:length local newpath' > `truncate' ) {
            local loops = ceil(`:length local newpath' / `truncate')
            mata: __gtools_pathpieces = J(1, `loops', "")
            mata: __gtools_pathcall   = ""
            mata: for(k = 1; k <= `loops'; k++) __gtools_pathpieces[k] = substr(st_local("newpath"), 1 + (k - 1) * `truncate', `truncate')
            mata: for(k = 1; k <= `loops'; k++) __gtools_pathcall = __gtools_pathcall + " `" + `"""' + __gtools_pathpieces[k] + `"""' + "' "
            mata: st_local("pathcall", __gtools_pathcall)
            mata: mata drop __gtools_pathcall __gtools_pathpieces
            cap plugin call env_set, PATH `pathcall'
        }
        else {
            cap plugin call env_set, PATH `"`path';`__gtools_hashpath'"'
        }
        if ( _rc ) {
            cap confirm file spookyhash.dll
            if ( _rc ) {
                cap plugin call env_set, PATH `"`__gtools_hashpath'"'
                if ( _rc ) {
                    local rc = _rc
                    di as err `"gtools: Unable to add '`__gtools_hashpath''"' ///
                              `"to system PATH."'                             ///
                        _n(1) `"gtools: download {browse "`url'":here}"'      ///
                              `" or run {opt gtools, dependencies}"'
                    exit `rc'
                }
            }
        }
    }
}

cap program drop gtools_plugin
if ( inlist("${GTOOLS_FORCE_PARALLEL}", "1") ) {
    cap program gtools_plugin, plugin using("gtools_`c_os_'_multi.plugin")
    if ( _rc ) {
        global GTOOLS_FORCE_PARALLEL 17900
        program gtools_plugin, plugin using("gtools_`c_os_'.plugin")
    }
}
else program gtools_plugin, plugin using("gtools_`c_os_'.plugin")
