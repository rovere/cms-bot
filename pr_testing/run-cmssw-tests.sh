#!/bin/bash -ex
# Takes GH_json as input and then clones base repo and merge PR into it
# ---
SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"  # Absolute path to script
CMS_BOT_DIR=$(dirname ${SCRIPTPATH})  # To get CMS_BOT dir path
WORKSPACE=$(dirname ${CMS_BOT_DIR} )
CACHED=${WORKSPACE}/CACHED            # Where cached PR metada etc are kept
COMMON=${CMS_BOT_DIR}/common
# ---

## TODO check if the variable there
# Input variable
PULL_REQUESTS=$PULL_REQUESTS              # "cms-sw/cmsdist#4488,cms-sw/cmsdist#4480,cms-sw/cmsdist#4479,cms-sw/root#116"
RELEASE_FORMAT=$RELEASE_FORMAT             # CMS SW TAG found in config_map.py
# PULL_REQUEST=$PULL_REQUEST              # CMSSW PR number, should avoid
# CMSDIST_PR=$CMSDIST_PR                  # CMSDIST PR number, should avoid
ARCHITECTURE=$ARCHITECTURE               # architecture (ex. slc6_amd64_gcc700)
# RELEASE_FORMAT=           # RELEASE_QUEUE found in config_map.py (ex. CMSSW_10_4_ROOT6_X )
# DO_TESTS=
# DO_SHORT_MATRIX=
# DO_STATIC_CHECKS=
# DO_DUPLICATE_CHECKS=
# MATRIX_EXTRAS=
# ADDITIONAL_PULL_REQUESTS=$ADDITIONAL_PULL_REQUESTS   # aditonal CMSSW PRs
# WORKFLOWS_FOR_VALGRIND_TEST=
AUTO_POST_MESSAGE=$AUTO_POST_MESSAGE
# RUN_CONFIG_VIEWER=
# USE_DAS_CACHE=
# BRANCH_NAME=
# APPLY_FIREWORKS_RULE=
# RUN_IGPROF=
# TEST_CLANG_COMPILATION=
# MATRIX_TIMEOUT=
# EXTRA_MATRIX_ARGS=
# DO_ADDON_TESTS=
# RUN_ON_SLAVE=
COMPARISON_ARCH= # TODO needs to be exported
# DISABLE_POISON=
# FULL_TOOLCONF=
PUB_USER=$PUB_USER
JENKINS_URL=$JENKINS_URL

WORKSPACE=$WORKSPACE
USER=$USER
BUILD_NUMBER=$BUILD_NUMBER
JOB_NAME=$JOB_NAME
# TODO delete after

function modify_comment_all_prs() {
    # modify all PR's with message that job has been triggered and add a link to jobs console
    for PR in ${PULL_REQUESTS} ; do
        PR_NAME_AND_REPO=$(echo ${PR} | sed 's/#.*//' )
        PR_NR=$(echo ${PR} | sed 's/.*#//' )
        $CMS_BOT_DIR/modify_comment.py -r ${PR_NAME_AND_REPO} -t JENKINS_TEST_URL \
            -m "https://cmssdt.cern.ch/${JENKINS_PREFIX}/job/${JOB_NAME}/${BUILD_NUMBER}/console Started: $(date '+%Y/%m/%d %H:%M')" ${PR_NR} $DRY_RUN || true
    done
}

# to not modify the behavior of other scripts that use the AUTO_POST_MESSAGE parameter
DRY_RUN=
if [ "X$AUTO_POST_MESSAGE" != Xtrue ]; then
  DRY_RUN='--no-post'
fi
source ${CMS_BOT_DIR}/jenkins-artifacts
voms-proxy-init -voms cms -valid 24:00 || true  # To get access to jenkins artifact machine
ls /cvmfs/cms-ib.cern.ch || true
JENKINS_PREFIX=$(echo "${JENKINS_URL}" | sed 's|/*$||;s|.*/||')
if [ "X${JENKINS_PREFIX}" = "X" ] ; then JENKINS_PREFIX="jenkins"; fi
if [ "X${PUB_USER}" = X ]; then PUB_USER="cms-sw" ; fi

### this is for triggering the comparison with the baseline
CMSDIST_ONLY=false  #
if [ "X$PULL_REQUEST" != X ]; then  # TODO PULL_reuqest should be done something with it
  PULL_REQUEST_NUMBER=$PULL_REQUEST  # Used mostly to comment
  PUB_REPO="${PUB_USER}/cmssw" # Repo to which comments will be published
else
  # If PULL_REQUEST is empty then we are only testing a CMSDIST PR, take that
  PULL_REQUEST_NUMBER=$CMSDIST_PR
  CMSDIST_ONLY=true
  PUB_REPO="${PUB_USER}/cmsdist"
fi

# PULL_REQUEST_JOB_ID=${BUILD_NUMBER}  # TODO Not used
modify_comment_all_prs # modify comments that test are being triggered by Jenkins

cd $WORKSPACE
CONFIG_MAP=$CMS_BOT_DIR/config.map
### to know at the end of the tests if everything went ok
ALL_OK=true
BUILD_OK=true
UNIT_TESTS_OK=true
RELVALS_OK=true
ADDON_OK=true
CLANG_BUILD_OK=true
RUN_TESTS=true
REAL_ARCH=-`cat /proc/cpuinfo | grep vendor_id | head -n 1 | sed "s/.*: //"`
export SCRAM_ARCH=$ARCHITECTURE
which scram 2>/dev/null || source /cvmfs/cms.cern.ch/cmsset_default.sh

COMPARISON_REL=
case $RELEASE_FORMAT in
  CMSSW_9_4_MAOD_X*|CMSSW_9_4_AN_X* ) COMP_QUEUE=$(echo $RELEASE_FORMAT | sed 's|_X.*|_X|') ;;
  * ) COMP_QUEUE=$(echo $RELEASE_FORMAT | sed 's|^\(CMSSW_[0-9]*_[0-9]*\)_.*|\1_X|') ;;
esac

IS_DEV_BRANCH=false
DEV_BRANCH=$(grep '^ *CMSSW_DEVEL_BRANCH *= *' $CMS_BOT_DIR/releases.py | sed 's| ||g;s|.*=||;s|"||g')
if [ "X$DEV_BRANCH" = "X$COMP_QUEUE" ] ; then IS_DEV_BRANCH=true ; fi

#If a CMSSW area already exists use it as it has been prepared by the CMSDIST test script
if [ ! -d CMSSW_* ]; then
  if [[ $RELEASE_FORMAT != *-* ]]; then
    RELEASE_QUEUE=$RELEASE_FORMAT
    COMP_ARCH=$COMPARISON_ARCH
    if [ "X$COMP_ARCH" = "X" ] ; then
      COMP_ARCH=$(cat $CONFIG_MAP | grep $COMP_QUEUE | grep -v "DISABLED=1" | grep "PROD_ARCH=1" | cut -d ";" -f 1 | cut -d "=" -f 2)
      if [ "X$COMP_ARCH" = "X" ] ; then COMP_ARCH=$ARCHITECTURE ; fi
    fi
    for SCRAM_REL in $(scram -a $SCRAM_ARCH l -c $RELEASE_FORMAT | grep -v -f "$CMS_BOT_DIR/ignore-releases-for-tests" | awk '{print $2}' | sort -r) ;  do
      if [ "$(echo $SCRAM_REL | sed 's|_X_.*|_X|')" = "$COMP_QUEUE" ] ; then
        COMP_REL=$SCRAM_REL
      else
        COMP_REL=$(echo $SCRAM_REL | sed 's|_[A-Z][A-Z0-9]*_X_|_X_|')
      fi
      has_jenkins_artifacts ib-baseline-tests/$COMP_REL/$COMP_ARCH/$REAL_ARCH/matrix-results/wf_errors.txt || continue
      RELEASE_FORMAT=$SCRAM_REL
      COMPARISON_ARCH=$COMP_ARCH
      COMPARISON_REL=$COMP_REL
      break
    done
    if [ "$RELEASE_FORMAT" = "$RELEASE_QUEUE" ] ; then
      RELEASE_FORMAT=$(scram -a $SCRAM_ARCH l -c $RELEASE_QUEUE | grep -v -f "$CMS_BOT_DIR/ignore-releases-for-tests" | awk '{print $2}' | sort -r | head -1)
      if [ "X$RELEASE_FORMAT" = "X" ] ; then
        # $CMS_BOT_DIR/report-pull-request-results RELEASE_NOT_FOUND --repo $PUB_REPO --pr $PULL_REQUEST_NUMBER --pr-job-id ${BUILD_NUMBER} $DRY_RUN
        exit 0
      fi
    fi
  else
    RELEASE_QUEUE=`$CMS_BOT_DIR/get-pr-branch $PULL_REQUEST ${PUB_USER}/cmssw`
  fi
else
  RELEASE_FORMAT=$( find $WORKSPACE -maxdepth 1 -name "CMSSW_*" -printf '%f\n' )
  RELEASE_QUEUE=$( echo $RELEASE_FORMAT | sed 's|_X.*|_X|' )
fi
[ "X$COMP_QUEUE" = "X" ] && COMP_QUEUE=$(echo $RELEASE_QUEUE | sed 's|^\(CMSSW_[0-9]*_[0-9]*\)_.*|\1_X|')

if [ "X$COMPARISON_REL" = "X" ] ; then
  case $RELEASE_FORMAT in
    CMSSW_9_4_MAOD_X*|CMSSW_9_4_AN_X* ) COMPARISON_REL=$RELEASE_FORMAT ;;
    * ) COMPARISON_REL=$(echo $RELEASE_FORMAT | sed 's|_[A-Z][A-Z0-9]*_X_|_X_|')
  esac
fi

if [ "X$COMPARISON_ARCH" = "X" ] ; then
  COMPARISON_ARCH=$(cat $CONFIG_MAP | grep $COMP_QUEUE | grep -v "DISABLED=1" | grep "PROD_ARCH=1" | cut -d ";" -f 1 | cut -d "=" -f 2) #Always take the prod architecture for comparison tests.
  if [ "X$COMPARISON_ARCH" = "X" ] ; then COMPARISON_ARCH=$ARCHITECTURE ; fi
fi

USE_DAS_SORT=YES
has_jenkins_artifacts ib-baseline-tests/$COMPARISON_REL/$COMPARISON_ARCH/$REAL_ARCH/matrix-results/used-ibeos-sort || USE_DAS_SORT=NO

# creation of results summary file
cp $CMS_BOT_DIR/templates/PullRequestSummary.html $WORKSPACE/summary.html
sed -e "s|@JENKINS_PREFIX@|$JENKINS_PREFIX|g;s|@REPOSITORY@|$PUB_REPO|g" $CMS_BOT_DIR/templates/js/renderPRTests.js > $WORKSPACE/renderPRTests.js
RESULTS_FILE=$WORKSPACE/testsResults.txt
touch $RESULTS_FILE
echo 'PR_NUMBER;'$PULL_REQUEST_NUMBER >> $RESULTS_FILE
echo 'ADDITIONAL_PRS;'$ADDITIONAL_PULL_REQUESTS >> $RESULTS_FILE
echo 'BASE_IB;'$RELEASE_FORMAT >> $RESULTS_FILE
echo 'BUILD_NUMBER;'$BUILD_NUMBER >> $RESULTS_FILE

case $RELEASE_FORMAT in
  *SLHC*) DO_ADDON_TESTS=false ;;
esac

if [ ! -d CMSSW_* ]; then
  scram -a $SCRAM_ARCH  project $RELEASE_FORMAT
  cd $RELEASE_FORMAT
else
  cd $WORKSPACE/$RELEASE_FORMAT
fi

sed -i -e 's|^define  *processTmpMMDData.*|processTmpMMDData=true\ndefine processTmpMMDDataXX|;s|^define  *processMMDData.*|processMMDData=true\ndefine processMMDDataXX|' config/SCRAM/GMake/Makefile.rules
set +x
eval $(scram run -sh)
set -x
python -c 'from requests import __version__ as v;print v;x=v.split(".");print int(x[0])*10000+int(x[1])*100+int(x[2])' || true
REQ_OK=$(python -c 'from requests import __version__ as v;x=v.split(".");print int(x[0])*10000+int(x[1])*100+int(x[2])>=20300' 2>/dev/null || echo False)
REQ_OK="True"
if [ "X$REQ_OK" = "XFalse" ] ; then
  pushd $WORKSPACE
    wget --no-check-certificate https://pypi.python.org/packages/source/r/requests/requests-2.3.0.tar.gz#md5=7449ffdc8ec9ac37bbcd286003c80f00
    tar -xvf requests-2.3.0.tar.gz
    sed -i -e 's|^DEFAULT_RETRIES *=.*|DEFAULT_RETRIES=10|' requests-2.3.0/requests/adapters.py
    if [ -z $PYTHONPATH ] ; then 
      export PYTHONPATH=$WORKSPACE/requests-2.3.0
    else
      export PYTHONPATH=$PYTHONPATH:$WORKSPACE/requests-2.3.0
    fi
  popd
fi
BUILD_LOG_DIR="${CMSSW_BASE}/tmp/${SCRAM_ARCH}/cache/log"
ANALOG_CMD="scram build outputlog && ($CMS_BOT_DIR/buildLogAnalyzer.py --logDir ${BUILD_LOG_DIR}/src || true)"
# $CMS_BOT_DIR/report-pull-request-results TESTS_RUNNING --repo $PUB_REPO --pr $PULL_REQUEST_NUMBER --pr-job-id ${BUILD_NUMBER} --add-message "Test started: $RELEASE_FORMAT for $SCRAM_ARCH" $DRY_RUN
cd $WORKSPACE/$RELEASE_FORMAT/src
git config --global --replace-all merge.renamelimit 2500

GIT_MERGE_RESULT_FILE=$WORKSPACE/git-merge-result
RECENT_COMMITS_FILE=$WORKSPACE/git-recent-commits
MB_COMPARISON=NO
touch $RECENT_COMMITS_FILE
# use the branch name if necesary
if [ "X$CMSDIST_ONLY" = Xfalse ]; then # If a CMSSW specific PR was specified
  (git cms-merge-topic --ssh -u ${PUB_USER}:$PULL_REQUEST && echo 'ALL_OK') 2>&1 | tee -a $GIT_MERGE_RESULT_FILE

  # this is to test several pull requests at the same time
  for PR in ${ADDITIONAL_PULL_REQUESTS//,/ }; do
    echo 'I will add the following pull request to the test'
    echo $PR;
    if [ "${PUB_USER}" = "cms-sw" ]; then
      git cms-merge-topic --ssh -u $PR 2>&1 | tee -a $GIT_MERGE_RESULT_FILE
    else
      /cvmfs/cms-ib.cern.ch/jenkins-env/git-tools/git-cms-merge-topic -u ${PUB_USER}:${PR} 2>&1 | tee -a $GIT_MERGE_RESULT_FILE
    fi
  done

  if grep 'Automatic merge failed' $GIT_MERGE_RESULT_FILE; then
#    $CMS_BOT_DIR/report-pull-request-results NOT_MERGEABLE --repo $PUB_REPO --pr $PULL_REQUEST_NUMBER --pr-job-id ${BUILD_NUMBER} $DRY_RUN
    exit 0
  fi

  if grep "Couldn't find remote ref" $GIT_MERGE_RESULT_FILE; then
    echo "Please add the branch name to the parameters"
#    $CMS_BOT_DIR/report-pull-request-results REMOTE_REF_ISSUE --repo $PUB_REPO --pr $PULL_REQUEST_NUMBER --pr-job-id ${BUILD_NUMBER} $DRY_RUN
    exit 1
  fi

  git diff --name-only $CMSSW_VERSION > $WORKSPACE/changed-files

  # look for any other error in general
  if ! grep "ALL_OK" $GIT_MERGE_RESULT_FILE; then
    echo "There was an error while running git cms-merge-topic"
#    $CMS_BOT_DIR/report-pull-request-results GIT_CMS_MERGE_TOPIC_ISSUE --repo $PUB_REPO --pr $PULL_REQUEST_NUMBER --pr-job-id ${BUILD_NUMBER} $DRY_RUN
    exit 0
  fi

  #############################################
  # Check if there are unwanted commits that came with the merge.
  ############################################
  RECENT_COMMITS_LOG_FILE=$WORKSPACE/git-log-recent-commits

  #IB_DATE=$(git show ${RELEASE_FORMAT} --pretty='format:%ai')
  git rev-list ${RELEASE_FORMAT}..HEAD --merges 2>&1 | tee -a $RECENT_COMMITS_FILE
  git log ${RELEASE_FORMAT}..HEAD --merges 2>&1      | tee -a $RECENT_COMMITS_LOG_FILE
  if [ $(grep 'Geometry' $WORKSPACE/changed-files | wc -l) -gt 0 ] ; then
    has_jenkins_artifacts material-budget/$RELEASE_FORMAT/$SCRAM_ARCH/Images && MB_COMPARISON=YES
  fi
fi

#If Fireworks is the only package involved I only compile and run unit tests
ONLY_FIREWORKS=false
if [ "X$APPLY_FIREWORKS_RULE" = Xtrue ]; then
  ls $WORKSPACE/$RELEASE_FORMAT/src
  NUM_DIRS=$(find $WORKSPACE/$RELEASE_FORMAT/src -mindepth 1 -maxdepth 1 -type d -print | grep -v '.git' | wc -l)
  if [ "$NUM_DIRS" == 1 ]; then
    if [ -d "$WORKSPACE/$RELEASE_FORMAT/src/Fireworks" ] ; then
      ONLY_FIREWORKS=true
      echo 'This pr only involves Fireworks!'
      echo 'Only compiling and running unit tests'
    fi
  fi
fi

# Don't do the following if we are only testing CMSDIST PR
CMSSW_COMMIT=
if [ "X$CMSDIST_ONLY" == Xfalse ]; then
  #get the latest commit and mark it as pending
  LAST_COMMIT=$(eval $(scram unset -sh); $CMS_BOT_DIR/process-pull-request -c -r ${PUB_USER}/cmssw $PULL_REQUEST)
  if [ "X${LAST_COMMIT}" = "X" ]  ; then
    pushd $WORKSPACE/$RELEASE_FORMAT/src
      if [ "X$BRANCH_NAME" = X ]; then
        LAST_COMMIT=`git log ${PUB_USER}/refs/pull/$PULL_REQUEST/head --pretty="%H" | head -n1`
      else
        LAST_COMMIT=`git log ${BRANCH_NAME//:/\/} --pretty="%H" | head -n1`
      fi
    popd
  fi
  CMSSW_COMMIT=$LAST_COMMIT
#  $CMS_BOT_DIR/report-pull-request-results TESTS_RUNNING --repo $PUB_REPO --pr $PULL_REQUEST_NUMBER -c $LAST_COMMIT --pr-job-id ${BUILD_NUMBER} $DRY_RUN

  git log --oneline --merges ${CMSSW_VERSION}..
#  $CMS_BOT_DIR/report-pull-request-results TESTS_RUNNING --repo $PUB_REPO --pr $PULL_REQUEST_NUMBER -c $LAST_COMMIT --pr-job-id ${BUILD_NUMBER} --add-message "Compiling" $DRY_RUN
else
  LAST_COMMIT=$CMSDIST_COMMIT
fi

# #############################################
# test compilation with Clang
# ############################################
echo 'test clang compilation'

NEED_CLANG_TEST=false
if cat $CONFIG_MAP | grep $RELEASE_QUEUE | grep PRS_TEST_CLANG= | grep SCRAM_ARCH=$ARCHITECTURE; then
  NEED_CLANG_TEST=true
fi

if [ "X$TEST_CLANG_COMPILATION" = Xtrue -a $NEED_CLANG_TEST = true -a "X$CMSDIST_PR" = X ]; then
#  $CMS_BOT_DIR/report-pull-request-results TESTS_RUNNING --repo $PUB_REPO --pr $PULL_REQUEST_NUMBER -c $LAST_COMMIT --pr-job-id ${BUILD_NUMBER} --add-message "Testing Clang compilation" $DRY_RUN

  #first, add the command to the log
  CLANG_USER_CMD="USER_CUDA_FLAGS='--expt-relaxed-constexpr' USER_CXXFLAGS='-Wno-register -fsyntax-only' scram build -k -j $(${COMMON}/get_cpu_number.sh *2) COMPILER='llvm compile'"
  CLANG_CMD="scram b vclean && ${CLANG_USER_CMD} BUILD_LOG=yes && ${ANALOG_CMD}"
  echo $CLANG_USER_CMD > $WORKSPACE/buildClang.log

  (eval $CLANG_CMD && echo 'ALL_OK') 2>&1 | tee -a $WORKSPACE/buildClang.log

  TEST_ERRORS=`grep -E "^gmake: .* Error [0-9]" $WORKSPACE/buildClang.log` || true
  GENERAL_ERRORS=`grep "ALL_OK" $WORKSPACE/buildClang.log` || true
  for i in $(grep ": warning: " $WORKSPACE/buildClang.log | grep "/$RELEASE_FORMAT/" | sed "s|.*/$RELEASE_FORMAT/src/||;s|:.*||" | sort -u) ; do
    if [ $(grep "$i" $WORKSPACE/changed-files | wc -l) -gt 0 ] ; then
      echo $i >> $WORKSPACE/clang-new-warnings.log
      grep ": warning: " $WORKSPACE/buildClang.log | grep "/$i" >> $WORKSPACE/clang-new-warnings.log
    fi
  done
  if [ -e $WORKSPACE/clang-new-warnings.log ]  ; then
    echo 'CLANG_NEW_WARNINGS;ERROR,Clang Warnings to fix,See Log,clang-new-warnings.log' >> $RESULTS_FILE
    if $IS_DEV_BRANCH && [ $(echo "$IGNORE_BOT_TESTS" | tr ',' '\n' | grep '^CLANG-WARNINGS$' | wc -l) -eq 0 ] ; then
      RUN_TESTS=false
      ALL_OK=false
      CLANG_BUILD_OK=false
    fi
  fi

  if [ -d ${BUILD_LOG_DIR}/html ] ; then
    mv ${BUILD_LOG_DIR}/html $WORKSPACE/clang-logs
    echo 'CLANG_LOG;OK,Clang warnings summary,See Log,clang-logs' >> $RESULTS_FILE
  fi
  if [ "X$TEST_ERRORS" != "X" -o "X$GENERAL_ERRORS" = "X" ]; then
    echo "Errors when testing compilation with clang"
    echo 'CLANG_COMPILATION_RESULTS;ERROR' >> $RESULTS_FILE
    RUN_TESTS=false
    ALL_OK=false
    CLANG_BUILD_OK=false
  else
    echo "the clang compilation had no errors/warnings!!"
    echo 'CLANG_COMPILATION_RESULTS;OK' >> $RESULTS_FILE
  fi
else
  echo 'CLANG_COMPILATION_RESULTS;NOTRUN' >> $RESULTS_FILE
fi

#Do QA checks
#Code Rules
QA_RES="NOTRUN"
if [ "X$CMSDIST_ONLY" == "Xfalse" ]; then # If a CMSSW specific PR was specified
#  $CMS_BOT_DIR/report-pull-request-results TESTS_RUNNING --repo $PUB_REPO --pr $PULL_REQUEST_NUMBER -c $LAST_COMMIT --pr-job-id ${BUILD_NUMBER} --add-message "Running Code Rules Checks" $DRY_RUN
  mkdir $WORKSPACE/codeRules
  cmsCodeRulesChecker.py -s $WORKSPACE/codeRules -r 1,3 || true
  QA_RES="OK"
  for r in $(find $WORKSPACE/codeRules -name 'cmsCodeRule*.txt' -type f) ; do
    QA_COUNT=$(grep '^/' $r | sed 's|^/||' | sort | uniq | xargs -i grep '{}' $WORKSPACE/changed-files  | wc -l)
    if [ "X$QA_COUNT" = "X0" ] ; then
      rm -f $r
    else
      CRULE=$(echo $r | sed 's|.*/cmsCodeRule||;s|.txt$||')
      echo "Rule$CRULE $description: https://raw.githubusercontent.com/${PUB_USER}/cmssw/master/Utilities/ReleaseScripts/python/cmsCodeRules/config.py" > $r.new
      python -c "from Utilities.ReleaseScripts.cmsCodeRules.config import Configuration as x;print x['$CRULE']['description']" >> $r.new
      echo "" >> $r.new
      cat $r >> $r.new
      mv $r.new $r
      QA_RES="ERROR"
    fi
  done
fi
echo "CODE_RULES;${QA_RES}" >> $RESULTS_FILE

#
# Static checks
#
if [ "X$DO_STATIC_CHECKS" = "Xtrue" -a "$ONLY_FIREWORKS" = false -a "X$CMSDIST_PR" = X -a "$RUN_TESTS" = "true" ]; then
#  $CMS_BOT_DIR/report-pull-request-results TESTS_RUNNING --repo $PUB_REPO --pr $PULL_REQUEST_NUMBER -c $LAST_COMMIT --pr-job-id ${BUILD_NUMBER} --add-message "Running Static Checks" $DRY_RUN
  echo 'STATIC_CHECKS;OK' >> $RESULTS_FILE
  echo '--------------------------------------'
  pushd $WORKSPACE/$RELEASE_FORMAT
  git cms-addpkg --ssh Utilities/StaticAnalyzers
  mkdir $WORKSPACE/llvm-analysis
  USER_CXXFLAGS='-Wno-register' SCRAM_IGNORE_PACKAGES="Fireworks/% Utilities/StaticAnalyzers" USER_LLVM_CHECKERS="-enable-checker threadsafety -enable-checker cms -disable-checker cms.FunctionDumper" \
    scram b -k -j $(${COMMON}/get_cpu_number.sh *2) checker SCRAM_IGNORE_SUBDIRS=test 2>&1 | tee -a $WORKSPACE/llvm-analysis/runStaticChecks.log
  cp -R $WORKSPACE/$RELEASE_FORMAT/llvm-analysis/*/* $WORKSPACE/llvm-analysis || true
  echo 'END OF STATIC CHECKS'
  echo '--------------------------------------'
  popd
else
  echo 'STATIC_CHECKS;NOTRUN' >> $RESULTS_FILE
fi

scram build clean
git cms-checkdeps -A -a
CMSSW_PKG_COUNT=$(ls -d $LOCALRT/src/*/* | wc -l)
############################################
# Force the run of DQM tests if necessary
############################################
if ls $WORKSPACE/$RELEASE_FORMAT/src/| grep -i -E "dqm.*|HLTriggerOffline|Validation"; then
  echo "I will make sure that DQM tests will be run"
  if ls $WORKSPACE/$RELEASE_FORMAT/src/| grep "DQMServices"; then
    echo DQMServices is already there
      if ls $WORKSPACE/$RELEASE_FORMAT/src/DQMServices/| grep "Components"; then
        echo "and DQMServices/Components is there"
      else
        git cms-addpkg --ssh DQMServices/Components
      fi
  else
    echo "checking out DQMServices"
    git cms-addpkg --ssh DQMServices
  fi
fi
#############################################
# Remove poison if asked to do so
#############################################
if [ "X$DISABLE_POISON" = Xtrue ]; then
  if [ -d $WORKSPACE/CMSSW_*/poison ]; then
    rm -rf $WORKSPACE/CMSSW_*/poison
  fi
fi
# #############################################
# test header checks tests
# ############################################
CHK_HEADER_LOG_RES="NOTRUN"
CHK_HEADER_OK=true
if [ -f $WORKSPACE/$RELEASE_FORMAT/config/SCRAM/GMake/Makefile.chk_headers ] ; then
#  $CMS_BOT_DIR/report-pull-request-results TESTS_RUNNING --repo $PUB_REPO --pr $PULL_REQUEST_NUMBER -c $LAST_COMMIT --pr-job-id ${BUILD_NUMBER} --add-message "Running HeaderChecks" $DRY_RUN
  COMPILATION_CMD="scram b vclean && USER_CHECK_HEADERS_IGNORE='TrackingTools/GsfTools/interface/MultiGaussianStateCombiner.h %.i' scram build -k -j $(${COMMON}/get_cpu_number.sh) check-headers"
  echo $COMPILATION_CMD > $WORKSPACE/headers_chks.log
  (eval $COMPILATION_CMD && echo 'ALL_OK') 2>&1 | tee -a $WORKSPACE/headers_chks.log
  echo 'END OF HEADER CHEKS LOG'
  TEST_ERRORS=`grep -E "^gmake: .* Error [0-9]" $WORKSPACE/headers_chks.log` || true
  GENERAL_ERRORS=`grep "ALL_OK" $WORKSPACE/headers_chks.log` || true
  CHK_HEADER_LOG_RES="OK"
  CHK_HEADER_OK=true
  if [ "X$TEST_ERRORS" != "X" -o "X$GENERAL_ERRORS" = "X" ]; then
    CHK_HEADER_LOG_RES="ERROR"
    CHK_HEADER_OK=false
  fi
fi
echo "HEADER_CHECKS;${CHK_HEADER_LOG_RES},Header Consistency,See Log,headers_chks.log" >> $RESULTS_FILE
# #############################################
# test compilation with GCC
# ############################################
#$CMS_BOT_DIR/report-pull-request-results TESTS_RUNNING --repo $PUB_REPO --pr $PULL_REQUEST_NUMBER -c $LAST_COMMIT --pr-job-id ${BUILD_NUMBER} --add-message "Running Compilation" $DRY_RUN
COMPILATION_CMD="scram b vclean && BUILD_LOG=yes scram b -k -j $(${COMMON}/get_cpu_number.sh) && ${ANALOG_CMD}"
if [ "X$CMSDIST_PR" != X -a $(grep '^edm_checks:' $WORKSPACE/$RELEASE_FORMAT/config/SCRAM/GMake/Makefile.rules | wc -l) -gt 0 ] ; then
  COMPILATION_CMD="scram b vclean && BUILD_LOG=yes SCRAM_NOEDM_CHECKS=yes scram b -k -j $(${COMMON}/get_cpu_number.sh) && ${ANALOG_CMD} && scram b -k -j $(${COMMON}/get_cpu_number.sh) edm_checks"
fi
echo $COMPILATION_CMD > $WORKSPACE/build.log
(eval $COMPILATION_CMD && echo 'ALL_OK') 2>&1 | tee -a $WORKSPACE/build.log
if [ -d ${BUILD_LOG_DIR}/html ] ; then mv ${BUILD_LOG_DIR}/html ${WORKSPACE}/build-logs ; fi
echo 'END OF BUILD LOG'
echo '--------------------------------------'

TEST_ERRORS=`grep -E "^gmake: .* Error [0-9]" $WORKSPACE/build.log` || true
GENERAL_ERRORS=`grep "ALL_OK" $WORKSPACE/build.log` || true

for i in $(grep ": warning: " $WORKSPACE/build.log | grep "/$RELEASE_FORMAT/" | sed "s|.*/$RELEASE_FORMAT/src/||;s|:.*||" | sort -u) ; do
  if [ $(grep "$i" $WORKSPACE/changed-files | wc -l) -gt 0 ] ; then
    echo $i >> $WORKSPACE/new-build-warnings.log
    grep ": warning: " $WORKSPACE/build.log | grep "/$i" >> $WORKSPACE/new-build-warnings.log
  fi
done
if [ -e $WORKSPACE/new-build-warnings.log ]  ; then
    echo 'BUILD_NEW_WARNINGS;ERROR,Compilation Warnings to fix,See Log,new-build-warnings.log' >> $RESULTS_FILE
    if $IS_DEV_BRANCH && [ $(echo "$IGNORE_BOT_TESTS" | tr ',' '\n' | grep '^BUILD-WARNINGS$' | wc -l) -eq 0 ] ; then
      RUN_TESTS=false
      ALL_OK=false
      BUILD_OK=false
    fi
fi
BUILD_LOG_RES="ERROR"
if [ "X$TEST_ERRORS" != "X" -o "X$GENERAL_ERRORS" = "X" ]; then
    echo "Errors when building"
    echo 'COMPILATION_RESULTS;ERROR' >> $RESULTS_FILE
    RUN_TESTS=false
    ALL_OK=false
    BUILD_OK=false
else
    echo "the build had no errors!!"
    echo 'COMPILATION_RESULTS;OK' >> $RESULTS_FILE
    if [ -e ${WORKSPACE}/build-logs/index.html ] ; then
      if [ $(grep '<td> *[1-9][0-9]* *</td>' ${WORKSPACE}/build-logs/index.html  | grep -iv ' href' | grep -v 'ignoreWarning' | wc -l) -eq 0 ] ; then
        BUILD_LOG_RES="OK"
      fi
    elif [ ! -d ${BUILD_LOG_DIR}/src ] ; then
      BUILD_LOG_RES="OK"
    fi
fi
echo "BUILD_LOG;${BUILD_LOG_RES}" >> $RESULTS_FILE

#Copy the cmssw ib das_client wrapper in PATH
cp -f $CMS_BOT_DIR/das-utils/das_client $CMS_BOT_DIR/das-utils/das_client.py
##FIXME: Remove the following das_client.py link once all IBs use das_client wrapper
set +x ; eval $(scram run -sh) ;set -x
#Drop RELEASE_TOP/external/SCRAM_ARCH/data if LOCALTOP/external/SCRAM_ARCH/data exists
#to make sure external packages removed files are not picked up from release directory
if [ "X$CMSDIST_PR" != "X" ] ; then
  export CMSSW_SEARCH_PATH=$(echo $CMSSW_SEARCH_PATH | tr ':' '\n'  | grep -v "$CMSSW_RELEASE_BASE/external/" | tr '\n' ':')
fi
export PATH=$CMS_BOT_DIR/das-utils:$PATH
which das_client

[ "X$USE_DAS_SORT" = "XYES" ] && $CMS_BOT_DIR/das-utils/use-ibeos-sort

#Duplicate dict
QA_RES="NOTRUN"
if [ "X$DO_DUPLICATE_CHECKS" = Xtrue -a "$ONLY_FIREWORKS" = false -a "X$CMSDIST_ONLY" == "Xfalse" -a "$RUN_TESTS" = "true" ]; then
#  $CMS_BOT_DIR/report-pull-request-results TESTS_RUNNING --repo $PUB_REPO --pr $PULL_REQUEST_NUMBER -c $LAST_COMMIT --pr-job-id ${BUILD_NUMBER} --add-message "Running Duplicate Dict Checks" $DRY_RUN
  mkdir $WORKSPACE/dupDict
  QA_RES="OK"
  for type in dup lostDefs edmPD ; do
    duplicateReflexLibrarySearch.py --${type} 2>&1 | grep -v ' SKIPPING ' > $WORKSPACE/dupDict/${type}.txt || true
  done
  QA_COUNT=$(cat $WORKSPACE/dupDict/dup.txt | grep '^  *[.]/[A-Z]' | sed 's|^  *./||' | sort | uniq | xargs -i grep '{}' $WORKSPACE/changed-files  | wc -l)
  if [ "X$QA_COUNT" != "X0" ] ; then QA_RES="ERROR" ; fi
  QA_COUNT=$(cat $WORKSPACE/dupDict/lostDefs.txt | grep '^[.]/[A-Z]' | sed 's|^./||' | sort | uniq | xargs -i grep '{}' $WORKSPACE/changed-files  | wc -l)
  if [ "X$QA_COUNT" != "X0" ] ; then QA_RES="ERROR" ; fi
  if [ -s $WORKSPACE/dupDict/edmPD ] ; then QA_RES="ERROR" ; fi
fi
echo "DUPLICATE_DICT_RULES;${QA_RES}" >> $RESULTS_FILE

#
# Unit tests
#
if [ "X$DO_TESTS" = Xtrue -a "X$BUILD_OK" = Xtrue -a "$RUN_TESTS" = "true" ]; then
#  $CMS_BOT_DIR/report-pull-request-results TESTS_RUNNING --repo $PUB_REPO --pr $PULL_REQUEST_NUMBER -c $LAST_COMMIT --pr-job-id ${BUILD_NUMBER} --add-message "Running Unit Tests" $DRY_RUN
  echo '--------------------------------------'
  UT_TIMEOUT=$(echo 7200+${CMSSW_PKG_COUNT}*20 | bc)
  UTESTS_CMD="CMS_PATH=/cvmfs/cms-ib.cern.ch/week0 timeout ${UT_TIMEOUT} scram b -k -j $(${COMMON}/get_cpu_number.sh)  runtests "
  echo $UTESTS_CMD > $WORKSPACE/unitTests.log
  (eval $UTESTS_CMD && echo 'ALL_OK') > $WORKSPACE/unitTests.log 2>&1
  echo 'END OF UNIT TESTS'
  echo '--------------------------------------'
  #######################################
  # check if DQM Tests where run
  #######################################
  if ls $WORKSPACE/$RELEASE_FORMAT/src/DQMServices/Components/test/ | grep -v -E "[a-z]+"; then 
    echo "DQM Tests were run!"
    pushd $WORKSPACE/$RELEASE_FORMAT/src/DQMServices/Components/test/
    ls | grep -v -E "[a-z]+" | xargs -I ARG mv ARG DQMTestsResults
    mkdir $WORKSPACE/DQMTestsResults
    cp -r DQMTestsResults $WORKSPACE/DQMTestsResults
    ls $WORKSPACE
    popd

    echo 'DQM_TESTS;OK' >> $RESULTS_FILE
  else
    echo 'DQM_TESTS;NOTRUN' >> $RESULTS_FILE
  fi

  TEST_ERRORS=$(grep -i 'had errors\|recipe for target' $WORKSPACE/unitTests.log | sed "s|'||g;s|.*recipe for target *||;s|.*unittests_|---> test |;s| failed$| timeout|" || true)
  TEST_ERRORS=`grep -i "had errors" $WORKSPACE/unitTests.log` || true
  GENERAL_ERRORS=`grep "ALL_OK" $WORKSPACE/unitTests.log` || true

  if [ "X$TEST_ERRORS" != "X" -o "X$GENERAL_ERRORS" = "X" ]; then
    echo "Errors in the unit tests"
    echo 'UNIT_TEST_RESULTS;ERROR' >> $RESULTS_FILE
    ALL_OK=false
    UNIT_TESTS_OK=false
  else
    echo 'UNIT_TEST_RESULTS;OK' >> $RESULTS_FILE
  fi


else

  echo 'UNIT_TEST_RESULTS;NOTRUN' >> $RESULTS_FILE
  echo 'DQM_TESTS;NOTRUN' >> $RESULTS_FILE

fi

#
# Matrix tests
#

MATRIX_EXTRAS=$(echo $(grep 'PR_TEST_MATRIX_EXTRAS=' $CMS_BOT_DIR/cmssw-pr-test-config | sed 's|.*=||'),${MATRIX_EXTRAS} | tr ' ' ','| tr ',' '\n' | grep '^[0-9]' | sort | uniq | tr '\n' ',' | sed 's|,*$||')
if [ ! "X$MATRIX_EXTRAS" = X ]; then
  MATRIX_EXTRAS="-l $MATRIX_EXTRAS"
fi

if [ "X$DO_SHORT_MATRIX" = Xtrue -a "X$BUILD_OK" = Xtrue -a "$ONLY_FIREWORKS" = false -a "$RUN_TESTS" = "true" ]; then
#  $CMS_BOT_DIR/report-pull-request-results TESTS_RUNNING --repo $PUB_REPO --pr $PULL_REQUEST_NUMBER -c $LAST_COMMIT --pr-job-id ${BUILD_NUMBER} --add-message "Running RelVals" $DRY_RUN
  echo '--------------------------------------'
  mkdir "$WORKSPACE/runTheMatrix-results"
  pushd "$WORKSPACE/runTheMatrix-results"
    case $RELEASE_FORMAT in
      *SLHCDEV*)
        SLHC_PARAM='-w upgrade'
        WF_LIST="-l 10000,10061,10200,10261,10800,10861,12200,12261,14400,14461,12600,12661,14000,14061,12800,12861,13000,13061,13800,13861"
        ;;
      *SLHC*)
        SLHC_PARAM='-w upgrade'
        WF_LIST="-l 10000,10061,10200,10261,12200,12261,14400,14461,12600,12661,14000,14061,12800,12861,13000,13061,13800,13861"
        ;;
      *)
        WF_LIST="-s $MATRIX_EXTRAS"
        ;;
    esac

    # MATRIX_TIMEOUT is set by jenkins
    dateBefore=$(date +"%s")
    [ $(runTheMatrix.py --help | grep 'job-reports' | wc -l) -gt 0 ] && EXTRA_MATRIX_ARGS="--job-reports $EXTRA_MATRIX_ARGS"
    RELVALS_CMD="CMS_PATH=/cvmfs/cms-ib.cern.ch/week0 timeout $MATRIX_TIMEOUT runTheMatrix.py $EXTRA_MATRIX_ARGS $SLHC_PARAM -j $(${COMMON}/get_cpu_number.sh -2) $WF_LIST"
    echo $RELVALS_CMD > $WORKSPACE/matrixTests.log
    (eval $RELVALS_CMD && echo 'ALL_OK') 2>&1 | tee -a $WORKSPACE/matrixTests.log
    WORKFLOW_TO_COMPARE=$(grep '^[1-9][0-9]*' $WORKSPACE/matrixTests.log | grep ' Step[0-9]' | sed 's|_.*||' | tr '\n' ',' | sed 's|,$||')

    dateAfter=$(date +"%s")
    diff=$(($dateAfter-$dateBefore))

    if [ "$diff" -ge $MATRIX_TIMEOUT ]; then
      echo "------------"  >> $WORKSPACE/matrixTests.log
      echo 'ERROR TIMEOUT' >> $WORKSPACE/matrixTests.log
    fi
  popd

  TEST_ERRORS=`grep -i -E "ERROR .*" $WORKSPACE/matrixTests.log` || true
  GENERAL_ERRORS=`grep "ALL_OK" $WORKSPACE/matrixTests.log` || true

  if [ "X$TEST_ERRORS" != "X" -o "X$GENERAL_ERRORS" = "X" ]; then
    echo "Errors in the RelVals"
    echo 'MATRIX_TESTS;ERROR' >> $RESULTS_FILE
    echo 'COMPARISON;NOTRUN' >> $RESULTS_FILE
    ALL_OK=false
    RELVALS_OK=false
  else
    echo "no errors in the RelVals!!"
    echo 'MATRIX_TESTS;OK' >> $RESULTS_FILE
    echo 'COMPARISON;QUEUED' >> $RESULTS_FILE

    TRIGGER_COMPARISON_FILE=$WORKSPACE/'comparison.properties'
    echo "Creating properties file $TRIGGER_COMPARISON_FILE"
    echo "RELEASE_FORMAT=$COMPARISON_REL" > $TRIGGER_COMPARISON_FILE
    echo "ARCHITECTURE=${ARCHITECTURE}" >> $TRIGGER_COMPARISON_FILE
    echo "PULL_REQUEST_NUMBER=$PULL_REQUEST_NUMBER" >> $TRIGGER_COMPARISON_FILE
    echo "PULL_REQUEST_JOB_ID=${BUILD_NUMBER}" >> $TRIGGER_COMPARISON_FILE
    echo "REAL_ARCH=$REAL_ARCH" >> $TRIGGER_COMPARISON_FILE
    echo "WORKFLOWS_LIST=${WORKFLOW_TO_COMPARE}" >> $TRIGGER_COMPARISON_FILE
    echo "COMPARISON_ARCH=$COMPARISON_ARCH" >> $TRIGGER_COMPARISON_FILE
    echo "CMSDIST_ONLY=$CMSDIST_ONLY" >> $TRIGGER_COMPARISON_FILE
    echo "PUB_REPO=$PUB_REPO" >> $TRIGGER_COMPARISON_FILE

    #####################################################################
    #### Run igprof
    #####################################################################
    # for now this is only run for 25202

    if [ "X$RUN_IGPROF" = Xtrue ]; then
      echo 'IGPROF;QUEQUED' >> $RESULTS_FILE

      TRIGGER_IGPROF_FILE=$WORKSPACE/'igprof.properties'
      echo "Creating properties file $TRIGGER_IGPROF_FILE"
      echo "RELEASE_FORMAT=$RELEASE_FORMAT" > $TRIGGER_IGPROF_FILE
      echo "ARCHITECTURE=${ARCHITECTURE}" >> $TRIGGER_IGPROF_FILE
      echo "PULL_REQUEST_NUMBER=$PULL_REQUEST_NUMBER" >> $TRIGGER_IGPROF_FILE
      echo "PULL_REQUEST_JOB_ID=${BUILD_NUMBER}" >> $TRIGGER_IGPROF_FILE
      echo "LAST_COMMIT=${LAST_COMMIT}" >> $TRIGGER_IGPROF_FILE
      echo "AUTO_POST_MESSAGE=${AUTO_POST_MESSAGE}" >> $TRIGGER_IGPROF_FILE
    else
      echo 'IGPROF;NOTRUN' >> $RESULTS_FILE
    fi

    #####################################################################
    #### Run cfg-viewer
    #####################################################################

    if [ "X$RUN_CONFIG_VIEWER" = Xtrue ]; then
      mkdir -p "$WORKSPACE/cfg-viewerResults"
      pushd "$WORKSPACE/cfg-viewerResults"
        cfg-viewer.py -r -s "$WORKSPACE/runTheMatrix-results"
      popd
      sed -i "s/<!--CONFIG_FILES_BROWSER//g" $WORKSPACE/summary.html
      sed -i "s/CONFIG_FILES_BROWSER-->//g" $WORKSPACE/summary.html
      sed -i "s/PARAM_CONFIG_BROWSER/https:\/\/cmssdt.cern.ch\/SDT\/${JENKINS_PREFIX}-artifacts\/${JOB_NAME}\/PR-${PULL_REQUEST}\/${BUILD_NUMBER}\/cfg-viewerResults\//g" $WORKSPACE/summary.html
    fi
  fi
else
  echo 'MATRIX_TESTS;NOTRUN' >> $RESULTS_FILE
  echo 'COMPARISON;NOTRUN' >> $RESULTS_FILE
  echo 'IGPROF;NOTRUN' >> $RESULTS_FILE
fi

#
# AddOn Tetss
#
if [ "X$DO_ADDON_TESTS" = Xtrue -a "X$BUILD_OK" = Xtrue -a "$RUN_TESTS" = "true" ]; then
#  $CMS_BOT_DIR/report-pull-request-results TESTS_RUNNING --repo $PUB_REPO --pr $PULL_REQUEST_NUMBER -c $LAST_COMMIT --pr-job-id ${BUILD_NUMBER} --add-message "Running AddOn Tests" $DRY_RUN
  #Some data files in cmssw_7_1/src directory are newer then cmsswdata. We make sure that we pick up these files from src instead of data.
  #Without this hack, pat1 addOnTest fails.
  EX_DATA_SEARCH="$CMSSW_SEARCH_PATH"
  case $RELEASE_FORMAT in
    CMSSW_7_1_* )
      for xdata_pkg in Geometry/CMSCommonData Geometry/ForwardCommonData Geometry/HcalCommonData Geometry/MuonCommonData Geometry/TrackerCommonData ; do
        if [ -e ${CMSSW_BASE}/external/${SCRAM_ARCH}/data/${xdata_pkg}/data ] ; then
          if [ ! -e ${CMSSW_BASE}/src/${xdata_pkg}/data ] ; then
            mkdir -p ${CMSSW_BASE}/xdata/${xdata_pkg}
            ln -s $CMSSW_RELEASE_BASE/src/${xdata_pkg}/data ${CMSSW_BASE}/xdata/${xdata_pkg}/data
            EX_DATA_SEARCH="${CMSSW_BASE}/xdata:$CMSSW_SEARCH_PATH"
          fi
        fi
      done
    ;;
  esac
  #End of 71x data hack
  echo '--------------------------------------'
  date
  ADDON_CMD="CMSSW_SEARCH_PATH=$EX_DATA_SEARCH CMS_PATH=/cvmfs/cms-ib.cern.ch/week0 timeout 7200 addOnTests.py -j $(${COMMON}/get_cpu_number.sh)"
  echo $ADDON_CMD > $WORKSPACE/addOnTests.log
  (eval $ADDON_CMD && echo 'ALL_OK') 2>&1 | tee -a $WORKSPACE/addOnTests.log
  date
  echo 'END OF ADDON TESTS'
  echo '--------------------------------------'
  if [ -d addOnTests ] ; then
    mv addOnTests $WORKSPACE/addOnTests
  fi
  TEST_ERRORS=`grep -i -E ": FAILED .*" $WORKSPACE/addOnTests.log` || true
  GENERAL_ERRORS=`grep "ALL_OK" $WORKSPACE/addOnTests.log` || true

  if [ "X$TEST_ERRORS" != "X" -o "X$GENERAL_ERRORS" = "X" ]; then
    echo "Errors in the addOnTests"
    echo 'ADDON_TESTS;ERROR' >> $RESULTS_FILE
    ALL_OK=false
    ADDON_OK=false
  else
    echo "no errors in the addOnTests!!"
    echo 'ADDON_TESTS;OK' >> $RESULTS_FILE
  fi
else
  echo 'ADDON_TESTS_RESULTS;NOTRUN' >> $RESULTS_FILE
fi

MB_TESTS_OK=NOTRUN
if [ "$MB_COMPARISON" = "YES" -a "X$BUILD_OK" = "Xtrue" -a "$RUN_TESTS" = "true" ] ; then
  if has_jenkins_artifacts material-budget/${CMSSW_VERSION}/${SCRAM_ARCH}/Images ; then
    mkdir $LOCALRT/material-budget
    MB_TESTS_OK=OK
    pushd $LOCALRT/material-budget
      $CMS_BOT_DIR/run-material-budget > $WORKSPACE/material-budget.log 2>&1 || MB_TESTS_OK=ERROR
      if [ "$MB_TESTS_OK" = "OK" ] ; then
        $CMS_BOT_DIR/compare-material-budget $LOCALRT/material-budget || MB_TESTS_OK=ERROR
      fi
    popd
    mv $LOCALRT/material-budget $WORKSPACE/material-budget
  fi
fi
echo "MATERIAL_BUDGET;${MB_TESTS_OK}" >> $RESULTS_FILE
if [ "$MB_TESTS_OK" = "ERROR" ] ; then
  MB_TESTS_OK=false
else
  MB_TESTS_OK=true
fi

#
# Valgrind tests
#
for WF in ${WORKFLOWS_FOR_VALGRIND_TEST//,/ }; do
#  $CMS_BOT_DIR/report-pull-request-results TESTS_RUNNING --repo $PUB_REPO --pr $PULL_REQUEST_NUMBER -c $LAST_COMMIT --pr-job-id ${BUILD_NUMBER} --add-message "Running Valgrind" $DRY_RUN

  echo 'I will run valgrind for the following workflow'
  echo $WF;
  mkdir -p "$WORKSPACE/valgrindResults-"$WF
  pushd "$WORKSPACE/valgrindResults-"$WF
  runTheMatrix.py --command '-n 10 --prefix "time valgrind --tool=memcheck --suppressions=$CMSSW_RELEASE_BASE/src/Utilities/ReleaseScripts/data/cms-valgrind-memcheck.supp --num-callers=20 --xml=yes --xml-file=valgrind.xml " ' -l $WF
  popd
done

#evaluate results
REPEAT=1
REPORT_PR=$PULL_REQUEST_NUMBER
if [ "X$PULL_REQUEST" == X ]; then
  COMMITS[1]=$CMSDIST_COMMIT
  REPOS[1]="${PUB_USER}/cmsdist"
  PR[1]=$CMSDIST_PR
  REPORT_PR=$CMSDIST_PR
elif [ "X$CMSDIST_PR" != X ]; then
  COMMITS[1]=$CMSSW_COMMIT
  REPOS[1]=$PUB_REPO
  PR[1]=$PULL_REQUEST_NUMBER
  COMMITS[2]=$CMSDIST_COMMIT
  REPOS[2]="${PUB_USER}/cmsdist"
  PR[2]=$CMSDIST_PR
  REPEAT=2
else
  COMMITS[1]=$LAST_COMMIT
  REPOS[1]=$PUB_REPO
  PR[1]=$PULL_REQUEST_NUMBER
fi

TESTS_FAILED="Failed tests:"
if [ "X$BUILD_OK" = Xfalse ]; then
  TESTS_FAILED="$TESTS_FAILED  Build"
  if [ "X$CHK_HEADER_OK" = Xfalse ] ; then
    TESTS_FAILED="$TESTS_FAILED  HeaderConsistency"
  fi
fi
if [ "X$UNIT_TESTS_OK" = Xfalse ]; then
  TESTS_FAILED="$TESTS_FAILED  UnitTests"
fi
if [ "X$RELVALS_OK" = Xfalse ]; then
  TESTS_FAILED="$TESTS_FAILED  RelVals"
fi
if [ "X$ADDON_OK" = Xfalse ]; then
  TESTS_FAILED="$TESTS_FAILED  AddOn"
fi
if [ "X$CLANG_BUILD_OK" = Xfalse ]; then
  TESTS_FAILED="$TESTS_FAILED  ClangBuild"
fi

cd $WORKSPACE
mkdir -p upload
for f in build-logs clang-logs runTheMatrix-results llvm-analysis *.log *.html *.txt *.js DQMTestsResults valgrindResults-* cfg-viewerResults igprof-results-data git-merge-result git-log-recent-commits addOnTests codeRules dupDict material-budget ; do
  [ -e $f ] && mv $f upload/$f
done
[ -e upload/renderPRTests.js ] && mkdir -p upload/js && mv upload/renderPRTests.js upload/js/
[ -e upload/matrixTests.log  ] && mkdir -p upload/runTheMatrix-results && mv upload/matrixTests.log upload/runTheMatrix-results/
[ -d upload/addOnTests       ] && find upload/addOnTests -name '*.root' -type f | xargs rm -f

rm -f $WORKSPACE/report.txt
for i in $( seq 1 $REPEAT); do
#  REPORT_OPTS="--report-pr ${REPORT_PR} --repo ${REPOS[$i]} --pr ${PR[$i]} -c ${COMMITS[$i]} --pr-job-id ${BUILD_NUMBER} --recent-merges $RECENT_COMMITS_FILE $DRY_RUN"
  if $ALL_OK ; then
    if [ "${BUILD_LOG_RES}" = "ERROR" ] ; then
      BUILD_LOG_RES=" --add-comment 'Compilation Warnings: Yes'"
    else
      BUILD_LOG_RES=""
    fi
    REPORT_OPTS[$i]="TESTS_OK_PR ${REPORT_OPTS} ${BUILD_LOG_RES}"
  else 
    echo "**${TESTS_FAILED}**" >  $WORKSPACE/report.txt
    REPORT_OPTS="--report-file $WORKSPACE/report.txt ${REPORT_OPTS}"
    if [ "X$BUILD_OK" = Xfalse ]; then
      $CMS_BOT_DIR/report-pull-request-results PARSE_BUILD_FAIL       -f $WORKSPACE/upload/build.log ${REPORT_OPTS}
    fi
    if [ "X$UNIT_TESTS_OK" = Xfalse ]; then
      $CMS_BOT_DIR/report-pull-request-results PARSE_UNIT_TESTS_FAIL  -f $WORKSPACE/upload/unitTests.log ${REPORT_OPTS}
    fi
    if [ "X$RELVALS_OK" = Xfalse ]; then
      $CMS_BOT_DIR/report-pull-request-results PARSE_MATRIX_FAIL      -f $WORKSPACE/upload/runTheMatrix-results/matrixTests.log ${REPORT_OPTS}
    fi
    if [ "X$ADDON_OK" = Xfalse ]; then
      $CMS_BOT_DIR/report-pull-request-results PARSE_ADDON_FAIL       -f $WORKSPACE/upload/addOnTests.log ${REPORT_OPTS}
    fi
    if [ "X$CLANG_BUILD_OK" = Xfalse ]; then
      $CMS_BOT_DIR/report-pull-request-results PARSE_CLANG_BUILD_FAIL -f $WORKSPACE/upload/buildClang.log ${REPORT_OPTS}
    fi
    if [ "X$MB_TESTS_OK" = Xfalse ]; then
      $CMS_BOT_DIR/report-pull-request-results MATERIAL_BUDGET        -f $WORKSPACE/upload/material-budget.log ${REPORT_OPTS}
    fi
    REPORT_OPTS[$i]="REPORT_ERRORS ${REPORT_OPTS}"
  fi
done
rm -f all_done
if [ -z ${DRY_RUN} ]; then
    send_jenkins_artifacts $WORKSPACE/upload pull-request-integration/PR-${PULL_REQUEST_NUMBER}/${BUILD_NUMBER} && touch all_done
    if [ -d $LOCALRT/das_query ] ; then
      send_jenkins_artifacts $LOCALRT/das_query das_query/PR-${PULL_REQUEST_NUMBER}/${BUILD_NUMBER}/PR || true
    fi
fi
if [ -f all_done ] ; then
  rm -f all_done
#  for i in $( seq 1 $REPEAT); do
#    $CMS_BOT_DIR/report-pull-request-results ${REPORT_OPTS[$i]}
#  done
else
  exit 1
fi

COMP_MSG="Comparison job queued."
if [ $(grep 'COMPARISON;NOTRUN' $WORKSPACE/upload/testsResults.txt | wc -l) -gt 0 ] ; then
  ERR_MSG="Build errors/Fireworks only changes/No short matrix requested"
  if [ "X$BUILD_OK" != "Xtrue" ] ; then
    ERR_MSG="Build errors"
  elif [ "X$RELVALS_OK" != "Xtrue" ] ; then
    ERR_MSG="runTheMatrix errors"
  elif [ "X$DO_SHORT_MATRIX" != "Xtrue" ] ; then
    ERR_MSG="short runTheMatrix was not requested"
  elif [ "X$ONLY_FIREWORKS" = "Xtrue" ] ; then
    ERR_MSG="Fireworks only changes in PR"
  fi
  COMP_MSG="Comparison not run due to ${ERR_MSG} (RelVals and Igprof tests were also skipped)"
fi
if [ "X$PULL_REQUEST" != X ] ; then
  $CMS_BOT_DIR/comment-gh-pr -r ${PUB_USER}/cmssw   -p $PULL_REQUEST -m "${COMP_MSG}" ${DRY_RUN} || true
fi
if [ "X$CMSDIST_PR" != X ] ; then
  $CMS_BOT_DIR/comment-gh-pr -r ${PUB_USER}/cmsdist -p $CMSDIST_PR   -m "${COMP_MSG}" ${DRY_RUN} || true
fi
