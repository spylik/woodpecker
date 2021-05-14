PROJECT = woodpecker

# --------------------------------------------------------------------
# Defining OTP version for this project which uses by kerl
# --------------------------------------------------------------------

ifneq ($(shell basename $(shell dirname $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST)))))), deps)
ERLANG_OTP = OTP-24.0-rc2
endif

# --------------------------------------------------------------------
# Compilation.
# --------------------------------------------------------------------

# if ERLC_OPTS not defined in parent project, we going to define by our-self
ERLC_OPTS ?= +warn_export_all +warn_export_vars +warn_unused_import +warn_untyped_record +warn_missing_spec +warn_missing_spec_all -Werror
ERLC_OPTS += +debug_info

TEST_ERLC_OPTS += +'{parse_transform, erlroute_transform}'
TEST_ERLC_OPTS += +debug_info

# --------------------------------------------------------------------
# Dependencies.
# --------------------------------------------------------------------

# if we part of deps directory, we using $(CURDIR)../ as DEPS_DIR
ifeq ($(shell basename $(shell dirname $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST)))))), deps)
    DEPS_DIR ?= $(shell dirname $(CURDIR))
endif

DEPS 		= gun
TEST_DEPS	= cowboy teaser erlroute
SHELL_DEPS	= sync

# our deps
dep_teaser 		= git https://github.com/spylik/teaser 		master
dep_erlroute 	= git https://github.com/spylik/erlroute	master
# 3-rd party deps
dep_gun 	    = git https://github.com/ninenines/gun				1.0.0
dep_ranch		= git https://github.com/ninenines/ranch			1.4.0
dep_cowboy      = git https://github.com/ninenines/cowboy.git       2.0.0

# use with travis
ifeq ($(USER),travis)
    TEST_DEPS += covertool
    dep_covertool = git https://github.com/idubrov/covertool
endif

# use with jenkins
ifeq ($(USER),jenkins)
    TEST_DEPS += covertool
    dep_covertool = git https://github.com/idubrov/covertool
endif


# --------------------------------------------------------------------
# Development enviroment ("make shell" to run it).
# --------------------------------------------------------------------

SHELL_OPTS = -config ${DEPS_DIR}/teaser/sys.config +c true +C multi_time_warp -pa ebin/ test/ -eval 'mlibs:discover()' -env ERL_LIBS deps -run mlibs autotest_on_compile

# --------------------------------------------------------------------
# We using erlang.mk
# --------------------------------------------------------------------

include erlang.mk
