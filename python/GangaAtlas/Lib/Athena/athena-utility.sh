#!/bin/sh

# function for resolving and setting TMPDIR env. variable
resolve_tmpdir () {
    if [ n$GANGA_ATHENA_WRAPPER_MODE = n'grid' ]; then
        #  - fistly respect the TMPDIR setup on WN
        #  - use SCRATCH_DIRECTORY from pre-WS globus gatekeeper 
        #  - use EDG_WL_SCRATCH from gLite middleware
        #  - use /tmp dir forcely in the worst case
        if [ -z $TMPDIR ]; then
            if [ ! -z $SCRATCH_DIRECTORY ]; then
                export TMPDIR=$SCRATCH_DIRECTORY  
            elif [ ! -z $EDG_WL_SCRATCH ]; then
                export TMPDIR=$EDG_WL_SCRATCH
            else 
                export TMPDIR=`mktemp -d /tmp/ganga_scratch_XXXXXXXX`
                if [ $? -ne 0 ]; then
                    echo "cannot create and setup TMPDIR"
                    exit 1
                fi
            fi
        fi
    elif [ n$GANGA_ATHENA_WRAPPER_MODE = n'local' ]; then
        #  - check if WORKDIR is given in the LSF case
        if [ ! -z $LSB_JOBID ] && [ ! -z $WORKDIR ]; then
            export TMPDIR=`mktemp -d $WORKDIR/ganga_scratch_XXXXXXXX`
        fi
    fi
}

## function for checking voms proxy information
check_voms_proxy() {
    echo "== voms-proxy-info -all =="
    voms-proxy-info -all
    echo "===="
}

## function for printing WN env. info 
print_wn_info () {
    echo "== hostname =="
    hostname -f
    echo "===="
    echo 

    echo "== system =="
    uname -a
    echo "===="
    echo 

    echo "==  env. variables =="
    env
    echo "===="
    echo 

    echo "==  disk usage  =="
    df
    echo "===="
    echo 
}

## function for setting up CMT environment
cmt_setup () {

    # setup ATLAS software
    unset CMTPATH
    
    export LCG_CATALOG_TYPE=lfc
    
    #  LFC Client Timeouts
    export LFC_CONNTIMEOUT=180
    export LFC_CONRETRY=2
    export LFC_CONRETRYINT=60
    
    # improve dcap reading speed
    export DCACHE_RAHEAD=TRUE
    #export DCACHE_RA_BUFFER=262144
  
    if [ n$GANGA_ATHENA_WRAPPER_MODE = n'grid' ]; then
        ATLAS_RELEASE_DIR=$VO_ATLAS_SW_DIR/software/$ATLAS_RELEASE
    elif [ n$GANGA_ATHENA_WRAPPER_MODE = n'local' ]; then
        ATLAS_RELEASE_DIR=$ATLAS_SOFTWARE/$ATLAS_RELEASE
    fi
 
    if [ ! -z `echo $ATLAS_RELEASE | grep 11.` ]; then
        source $ATLAS_RELEASE_DIR/setup.sh 
    elif [ ! -z `echo $ATLAS_RELEASE | grep 12.` ] || [ ! -z `echo $ATLAS_RELEASE | grep 13.` ] || [ ! -z `echo $ATLAS_RELEASE | grep 14.` ]; then
        #if [ n$ATLAS_PROJECT = n'AtlasPoint1' ]; then
        if [ ! -z $ATLAS_PROJECT ] && [ ! -z $ATLAS_PRODUCTION ]; then
            source $ATLAS_RELEASE_DIR/cmtsite/setup.sh -tag=$ATLAS_PRODUCTION,$ATLAS_PROJECT
        elif [ ! -z $ATLAS_PROJECT ]; then
            source $ATLAS_RELEASE_DIR/cmtsite/setup.sh -tag=$ATLAS_RELEASE,$ATLAS_PROJECT
        else
            source $ATLAS_RELEASE_DIR/cmtsite/setup.sh -tag=AtlasOffline,$ATLAS_RELEASE
        fi
    fi


    # print relevant env. variables for debug 
    echo "CMT setup:"
    env | grep 'CMT'
    echo "SITE setup:"
    env | grep 'SITE'
}

## function for setting up pre-installed dq2client tools on WN
dq2client_setup () {

    if [ ! -z $DQ2_CLIENT_VERSION ]; then

        ## client side version request
        source $VO_ATLAS_SW_DIR/ddm/$DQ2_CLIENT_VERSION/setup.sh

    else

        ## latest version: general case
        source $VO_ATLAS_SW_DIR/ddm/latest/setup.sh

    fi
  
    # check configuration
    echo "DQ2CLIENT setup:"
    env | grep 'DQ2_'
    which dq2-ls

    ## return 0 if dq2-ls is found in PATH; otherwise, return 1
    return $?
}

## function for getting grid proxy from a remote endpoint 
get_remote_proxy () {
    export X509_CERT_DIR=$X509CERTDIR
    if [ ! -z $REMOTE_PROXY ]; then
        scp -o StrictHostKeyChecking=no $REMOTE_PROXY $PWD/.proxy
        export X509_USER_PROXY=$PWD/.proxy
    fi

    # print relevant env. variables for debug 
    env | grep 'GLITE'
    env | grep 'X509'
    env | grep 'GLOBUS' 
    voms-proxy-info -all
}

## function for fixing g2c/gcc issues on SLC3/SLC4 against
## ATLAS release 11, 12, 13 
fix_gcc_issue () {
    # fix SL4 gcc problem
    RHREL=`cat /etc/redhat-release`
    SC41=`echo $RHREL | grep -c 'Scientific Linux CERN SLC release 4'`
    SC42=`echo $RHREL | grep -c 'Scientific Linux SL release 4'`
    which gcc32; echo $? > retcode.tmp
    retcode=`cat retcode.tmp`
    rm -f retcode.tmp
    if [ $retcode -eq 0 ] && ( [ $SC41 -gt 0 ] || [ $SC42 -gt 0 ] ) ; then
        mkdir comp
        cd comp

        cat - >gcc <<EOF
#!/bin/sh

/usr/bin/gcc32 -m32 \$*

EOF

        cat - >g++ <<EOF
#!/bin/sh

/usr/bin/g++32 -m32 \$*

EOF

        chmod +x gcc
        chmod +x g++
        cd ..
        export PATH=$PWD/comp:$PATH
        ln -s /usr/lib/gcc/i386-redhat-linux/3.4.3/libg2c.a $PWD/comp/libg2c.a
        export LD_LIBRARY_PATH=$PWD/comp:$LD_LIBRARY_PATH
        export LIBRARY_PATH=$PWD/comp:$LIBRARY_PATH
    fi

    # fix SL3 g2c problem
    SC31=`echo $RHREL | grep -c 'Scientific Linux'`
    SC32=`echo $RHREL | grep -c 'elease 3.0'`
    ls /usr/lib/libg2c.a; echo $? > retcode.tmp
    retcode=`cat retcode.tmp`
    rm -f retcode.tmp
    if [ $retcode -eq 1 ] &&  [ $SC31 -gt 0 ] && [ $SC32 -gt 0 ]  ; then
        ln -s /usr/lib/gcc-lib/i386-redhat-linux/3.2.3/libg2c.a $PWD/libg2c.a
        export LIBRARY_PATH=$PWD:$LIBRARY_PATH
    fi
}

## function for setting up athena runtime environment 
athena_setup () {

    echo "Setting up the Athena environment ..."

    if [ -z $USER_AREA ] && [ -z $ATHENA_USERSETUPFILE ]
    then
	runtime_setup
    elif [ ! -z $ATHENA_USERSETUPFILE ]
    then
        . $ATHENA_USERSETUPFILE
    else
	athena_compile
    fi
}

# Determine PYTHON executable in ATLAS release
get_pybin () {

    if [ n$GANGA_ATHENA_WRAPPER_MODE = n'local' ]; then
        ATLAS_PYBIN_LOOKUP_PATH=$ATLAS_SOFTWARE

    elif [ n$GANGA_ATHENA_WRAPPER_MODE = n'grid' ]; then
        ATLAS_PYBIN_LOOKUP_PATH=$VO_ATLAS_SW_DIR/prod/releases

    else
        echo "get_pybin not implemented"
    fi

    if [ ! -z `echo $ATLAS_RELEASE | grep 14.` ]; then
        export pybin=$(ls -r $ATLAS_PYBIN_LOOKUP_PATH/*/sw/lcg/external/Python/*/*/bin/python | head -1)
    else
        export pybin=$(ls -r $ATLAS_PYBIN_LOOKUP_PATH/*/sw/lcg/external/Python/*/slc3_ia32_gcc323/bin/python | head -1)
    fi

    # Determine python32 executable location 

    which python32; echo $? > retcode.tmp
    retcode=`cat retcode.tmp`
    rm -f retcode.tmp
    #if [ $retcode -eq 0 ] && [ -z `echo $ATLAS_RELEASE | grep 14.` ] ; then
    if [ $retcode -eq 0 ]; then
	export python32bin=`which python32`
    fi

}

# detecting the se type
detect_setype () {

    # given the library/binaray/python paths for data copy commands
    MY_LD_LIBRARY_PATH_ORG=$1
    MY_PATH_ORG=$2
    MY_PYTHONPATH_ORG=$3

    if [ -e ganga-stage-in-out-dq2.py ]; then

        chmod +x ganga-stage-in-out-dq2.py
    
        LD_LIBRARY_PATH_BACKUP=$LD_LIBRARY_PATH
        PATH_BACKUP=$PATH
        PYTHONPATH_BACKUP=$PYTHONPATH
        export LD_LIBRARY_PATH=$PWD:$MY_LD_LIBRARY_PATH_ORG:$LD_LIBRARY_PATH_BACKUP:/opt/globus/lib
        export PATH=$MY_PATH_ORG:$PATH_BACKUP
        export PYTHONPATH=$MY_PYTHONPATH_ORG:$PYTHONPATH_BACKUP

        # Remove lib64/python from PYTHONPATH
	dum=`echo $PYTHONPATH | tr ':' '\n' | egrep -v 'lib64/python' | tr '\n' ':' `
	export PYTHONPATH=$dum

	if [ ! -z $python32bin ]; then
	    export GANGA_SETYPE=`$python32bin ./ganga-stage-in-out-dq2.py --setype`
	else
	    if [ -e /usr/bin32/python ]
	    then	
		export GANGA_SETYPE=`/usr/bin32/python ./ganga-stage-in-out-dq2.py --setype`
            else
		export GANGA_SETYPE=`./ganga-stage-in-out-dq2.py --setype`
	    fi
		
	fi
	if [ -z $GANGA_SETYPE ]; then
	    export GANGA_SETYPE=`$pybin ./ganga-stage-in-out-dq2.py --setype`
	fi
        export LD_LIBRARY_PATH=$LD_LIBRARY_PATH_BACKUP
        export PATH=$PATH_BACKUP
        export PYTHONPATH=$PYTHONPATH_BACKUP
    fi
}

# staging input data files
stage_inputs () {

    # given the library/binaray/python paths for data copy commands
    MY_LD_LIBRARY_PATH_ORG=$1
    MY_PATH_ORG=$2
    MY_PYTHONPATH_ORG=$3

    # Unpack dq2info.tar.gz
    if [ -e dq2info.tar.gz ]; then
        tar xzf dq2info.tar.gz
    fi

    if [ -e input_files ]; then
	echo "Preparing input data ..."
        # DQ2Dataset
	if [ -e input_guids ] && [ -e ganga-stage-in-out-dq2.py ]; then
	    chmod +x ganga-stage-in-out-dq2.py
	    chmod +x dq2_get
	    LD_LIBRARY_PATH_BACKUP=$LD_LIBRARY_PATH
	    PATH_BACKUP=$PATH
	    PYTHONPATH_BACKUP=$PYTHONPATH
	    export LD_LIBRARY_PATH=$PWD:$MY_LD_LIBRARY_PATH_ORG:$LD_LIBRARY_PATH_BACKUP:/opt/globus/lib
	    export PATH=$MY_PATH_ORG:$PATH_BACKUP
	    export PYTHONPATH=$MY_PYTHONPATH_ORG:$PYTHONPATH_BACKUP

            # Remove lib64/python from PYTHONPATH
	    dum=`echo $PYTHONPATH | tr ':' '\n' | egrep -v 'lib64/python' | tr '\n' ':' `
	    export PYTHONPATH=$dum

	    if [ ! -z $python32bin ]; then
		$python32bin ./ganga-stage-in-out-dq2.py; echo $? > retcode.tmp
	    else
		if [ -e /usr/bin32/python ]; then
		    /usr/bin32/python ./ganga-stage-in-out-dq2.py; echo $? > retcode.tmp
		else
		    ./ganga-stage-in-out-dq2.py -v; echo $? > retcode.tmp
		fi
	    fi
	    retcode=`cat retcode.tmp`
	    rm -f retcode.tmp
            # Fail over
	    if [ $retcode -ne 0 ]; then
		$pybin ./ganga-stage-in-out-dq2.py -v; echo $? > retcode.tmp
		retcode=`cat retcode.tmp`
		rm -f retcode.tmp
	    fi

	    export LD_LIBRARY_PATH=$LD_LIBRARY_PATH_BACKUP
	    export PATH=$PATH_BACKUP
	    export PYTHONPATH=$PYTHONPATH_BACKUP
	    
        # ATLASDataset, ATLASCastorDataset, ATLASLocalDataset
	elif [ -e ganga-stagein-lfc.py ]; then 
	    chmod +x ganga-stagein-lfc.py
	    ./ganga-stagein-lfc.py -v -i input_files; echo $? > retcode.tmp
	    retcode=`cat retcode.tmp`
	    rm -f retcode.tmp
	elif [ -e ganga-stagein.py ]; then
	    chmod +x ganga-stagein.py
	    ./ganga-stagein.py -v -i input_files; echo $? > retcode.tmp
	    retcode=`cat retcode.tmp`
	    rm -f retcode.tmp
	else
	    if [ n$GANGA_ATHENA_WRAPPER_MODE = n'grid' ]; then
		retcode=410100
	    else
		cat input_files | while read file
		  do
		  pool_insertFileToCatalog $file 2>/dev/null; echo $? > retcode.tmp
		  retcode=`cat retcode.tmp`
		  rm -f retcode.tmp
		done
	    fi
	fi
    fi
}

# staging output files 
stage_outputs () {

    # given the library/binaray/python paths for data copy commands
    MY_LD_LIBRARY_PATH_ORG=$1
    MY_PATH_ORG=$2
    MY_PYTHONPATH_ORG=$3

    if [ $retcode -eq 0 ]
    then
        echo "Storing output data ..."
        if [ -e ganga-stage-in-out-dq2.py ] && [ -e output_files ] && [ ! -z $OUTPUT_DATASETNAME ]
        then
            chmod +x ganga-stage-in-out-dq2.py
            export DATASETTYPE=DQ2_OUT
            LD_LIBRARY_PATH_BACKUP=$LD_LIBRARY_PATH
            PATH_BACKUP=$PATH
            PYTHONPATH_BACKUP=$PYTHONPATH
            export LD_LIBRARY_PATH=$PWD:$MY_LD_LIBRARY_PATH_ORG:$LD_LIBRARY_PATH_BACKUP:/opt/globus/lib
            export PATH=$MY_PATH_ORG:$PATH_BACKUP
            export PYTHONPATH=$MY_PYTHONPATH_ORG:$PYTHONPATH_BACKUP

            # Remove lib64/python from PYTHONPATH
	    dum=`echo $PYTHONPATH | tr ':' '\n' | egrep -v 'lib64/python' | tr '\n' ':' `
	    export PYTHONPATH=$dum

	    if [ ! -z $python32bin ]; then
                $python32bin ./ganga-stage-in-out-dq2.py --output=output_files.new; echo $? > retcode.tmp
            else
                if [ -e /usr/bin32/python ]
                then
                    /usr/bin32/python ./ganga-stage-in-out-dq2.py --output=output_files.new; echo $? > retcode.tmp
                else
                    ./ganga-stage-in-out-dq2.py --output=output_files.new; echo $? > retcode.tmp
                fi
            fi
            retcode=`cat retcode.tmp`
            rm -f retcode.tmp
            # Fail over
            if [ $retcode -ne 0 ]; then
                $pybin ./ganga-stage-in-out-dq2.py --output=output_files.new; echo $? > retcode.tmp
                retcode=`cat retcode.tmp`
                rm -f retcode.tmp
            fi

            export LD_LIBRARY_PATH=$LD_LIBRARY_PATH_BACKUP
            export PATH=$PATH_BACKUP
            export PYTHONPATH=$PYTHONPATH_BACKUP

        elif [ -n "$OUTPUT_LOCATION" -a -e output_files ]; then

            if [ n$GANGA_ATHENA_WRAPPER_MODE = n'local' ]; then
                TEST_CMD=`which rfmkdir 2>/dev/null`
                if [ ! -z $TEST_CMD ]; then
                    MKDIR_CMD=$TEST_CMD
                else
                    MKDIR_CMD="mkdir" 
                fi

                TEST_CMD2=`which rfcp 2>/dev/null`
                if [ ! -z $TEST_CMD2 ]; then
                    CP_CMD=$TEST_CMD2
                else
                    CP_CMD="cp" 
                fi
             
                $MKDIR_CMD -p $OUTPUT_LOCATION
                cat output_files | while read filespec; do
                    for file in $filespec; do
                      $CP_CMD $file $OUTPUT_LOCATION/$file
                    done
                done

            elif [ n$GANGA_ATHENA_WRAPPER_MODE = n'grid' ]; then

                LD_LIBRARY_PATH_BACKUP=$LD_LIBRARY_PATH
                PATH_BACKUP=$PATH
                PYTHONPATH_BACKUP=$PYTHONPATH
                export LD_LIBRARY_PATH=$PWD:$MY_LD_LIBRARY_PATH_ORG:/opt/globus/lib:$LD_LIBRARY_PATH_BACKUP
                export PATH=$MY_PATH_ORG:$PATH_BACKUP
                export PYTHONPATH=$MY_PYTHONPATH_ORG:$PYTHONPATH_BACKUP

                ## copy and register files with 3 trials
                cat output_files | while read filespec; do
                    for file in $filespec; do
                        lcg-cr --vo atlas -t 300 -d $OUTPUT_LOCATION/$file file:$PWD/$file >> output_guids; echo $? > retcode.tmp
                        retcode=`cat retcode.tmp`
                        rm -f retcode.tmp
                        if [ $retcode -ne 0 ]; then
                            sleep 120
                            lcg-cr --vo atlas -t 300 -d $OUTPUT_LOCATION/$file file:$PWD/$file >> output_guids; echo $? > retcode.tmp
                            retcode=`cat retcode.tmp`
                            rm -f retcode.tmp
                            if [ $retcode -ne 0 ]; then
                                sleep 120
                                lcg-cr --vo atlas -t 300 -d $OUTPUT_LOCATION/$file file:$PWD/$file >> output_guids; echo $? > retcode.tmp
                                retcode=`cat retcode.tmp`
                                rm -f retcode.tmp
                                if [ $retcode -ne 0 ]; then
                                    # WRAPLCG_STAGEOUT_LCGCR
                                    retcode=410403
                                fi
                            fi
                        fi
                    done
                done

                export LD_LIBRARY_PATH=$LD_LIBRARY_PATH_BACKUP
                export PATH=$PATH_BACKUP
                export PYTHONPATH=$PYTHONPATH_BACKUP
            fi
        fi
    fi
}

# prepare athena
prepare_athena () { 

    # Set timing command
    if [ -x /usr/bin/time ]; then
	export timecmd="/usr/bin/time -v"
    else
	export timecmd=time
    fi

    # parse the job options
    if [ $retcode -eq 0 ] || [ n$DATASETTYPE = n'DQ2_COPY' ]; then

        echo "Parsing jobOptions ..."
        if [ ! -z $OUTPUT_JOBID ] && [ -e ganga-joboption-parse.py ] && [ -e output_files ]
        then
            chmod +x ganga-joboption-parse.py
            ./ganga-joboption-parse.py
        fi
    fi

   # Work around for glite WMS spaced environement variable problem
    if [ -e athena_options ] 
    then
	ATHENA_OPTIONS_NEW=`cat athena_options`
	if [ ! "$ATHENA_OPTIONS_NEW" = "$ATHENA_OPTIONS" ]
	then
	    export ATHENA_OPTIONS=$ATHENA_OPTIONS_NEW	
	fi
    fi
} 

# run athena
run_athena () {

    job_options=$*

# run athena in regular mode =========================================== 
    if [ $retcode -eq 0 ]; then
        ls -al
        env | grep DQ2
        env | grep LFC
	env | grep DCACHE

	cat input.py

	export LD_LIBRARY_PATH=$PWD:$LD_LIBRARY_PATH:$LD_LIBRARY_PATH_ORIG

        echo "Running Athena ..."
    if [ n$ATLAS_EXETYPE == n'ATHENA' ]
	    then 
	    $timecmd athena.py $ATHENA_OPTIONS input.py; echo $? > retcode.tmp
	    retcode=`cat retcode.tmp`
	    rm -f retcode.tmp
	elif [ n$ATLAS_EXETYPE == n'PYARA' ]
	    then
	    $timecmd $pybin $ATHENA_OPTIONS ; echo $? > retcode.tmp
	    retcode=`cat retcode.tmp`
	    rm -f retcode.tmp
	elif [ n$ATLAS_EXETYPE == n'ROOT' ]
	    then
	    $timecmd root -b -q $ATHENA_OPTIONS ; echo $? > retcode.tmp
	    retcode=`cat retcode.tmp`
	    rm -f retcode.tmp
	elif [ n$ATLAS_EXETYPE == n'TRF' ] && [ -e trf_params ]
	    then
	    if [ -e $VO_ATLAS_SW_DIR/ddm/latest/setup.sh ] || [ -e /afs/cern.ch/atlas/offline/external/GRID/ddm/DQ2Clients/latest/setup.sh ]
		then
		if [ -e $VO_ATLAS_SW_DIR/ddm/latest/setup.sh ] 
		    then
		    $VO_ATLAS_SW_DIR/ddm/latest/setup.sh 
		elif [ -e /afs/cern.ch/atlas/offline/external/GRID/ddm/DQ2Clients/latest/setup.sh ]
		    then
		    source /afs/cern.ch/atlas/offline/external/GRID/ddm/DQ2Clients/latest/setup.sh
		    export DQ2_LOCAL_SITE_ID=CERN
		fi
		dq2-get -d --automatic --timeout=300 --files=$DBFILENAME $DBDATASETNAME;  echo $? > retcode.tmp
		if [ -e $DBDATASETNAME/$DBFILENAME ]
		    then
		    mv $DBDATASETNAME/* .
		    echo $file > input.txt
		    echo successfully retrieved $DBFILENAME
		    break
		else
		    echo 'ERROR: dq2-get of $DBDATASETNAME failed !'
		    echo '1'>retcode.tmp
		fi

	    fi

	    grep 'ServiceMgr.EventSelector.InputCollections' input.py > input.py.new
	    sed 's/ServiceMgr.EventSelector.InputCollections = \[//' input.py.new > input.py.new2
	    sed 's/,\]//' input.py.new2 > input.py.new3
	    mv input.py.new3 input.py
	    ##
	    echo ' ...'
	    cat input.py
	    ##
	    ls -rtla
            ## need to remove local link to db, or the dbrelease specified in the trf will not have any effect
	    rm -rf sqlite200/ALLP200.db
	    ##
	    $timecmd $ATHENA_OPTIONS 'inputbsfile='`cat input.py` `cat trf_params` 'dbrelease='$DBFILENAME; echo $? > retcode.tmp
	    retcode=`cat retcode.tmp`
	    rm -f retcode.tmp
	else
	    $timecmd athena.py $ATHENA_OPTIONS input.py; echo $? > retcode.tmp
	    retcode=`cat retcode.tmp`
	    rm -f retcode.tmp
	fi
	
    fi
}

## routine for making file stager job option: input.py
make_filestager_joption() {

    # given the library/binaray/python paths for data copy commands
    MY_LD_LIBRARY_PATH_ORG=$1
    MY_PATH_ORG=$2
    MY_PYTHONPATH_ORG=$3

    if [ -f make_filestager_joption.py ]; then
        chmod +x make_filestager_joption.py

        LD_LIBRARY_PATH_BACKUP=$LD_LIBRARY_PATH
        PATH_BACKUP=$PATH
        PYTHONPATH_BACKUP=$PYTHONPATH
        export LD_LIBRARY_PATH=$PWD:$MY_LD_LIBRARY_PATH_ORG:$LD_LIBRARY_PATH_BACKUP:/opt/globus/lib
        export PATH=$MY_PATH_ORG:$PATH_BACKUP
        export PYTHONPATH=$MY_PYTHONPATH_ORG:$PYTHONPATH_BACKUP

            # Remove lib64/python from PYTHONPATH
        dum=`echo $PYTHONPATH | tr ':' '\n' | egrep -v 'lib64/python' | tr '\n' ':' `
        export PYTHONPATH=$dum

        if [ ! -z $python32bin ]; then
            $python32bin ./make_filestager_joption.py; echo $? > retcode.tmp
        else
            if [ -e /usr/bin32/python ]; then
                /usr/bin32/python ./make_filestager_joption.py; echo $? > retcode.tmp
            else
                ./make_filestager_joption.py; echo $? > retcode.tmp
            fi
        fi
        retcode=`cat retcode.tmp`
        rm -f retcode.tmp

        # Fail over
        if [ $retcode -ne 0 ]; then
            $pybin ./make_filestager_joption.py; echo $? > retcode.tmp
            retcode=`cat retcode.tmp`
            rm -f retcode.tmp
        fi

        export LD_LIBRARY_PATH=$LD_LIBRARY_PATH_BACKUP
        export PATH=$PATH_BACKUP
        export PYTHONPATH=$PYTHONPATH_BACKUP
    fi

    return 0
}

## function for setting up athena runtime environment, no compilation
runtime_setup () {

    if [ ! -z `echo $ATLAS_RELEASE | grep 11.` ]
    then
        source $SITEROOT/dist/$ATLAS_RELEASE/Control/AthenaRunTime/AthenaRunTime-*/cmt/setup.sh
    elif [ ! -z `echo $ATLAS_RELEASE | grep 12.` ] || [ ! -z `echo $ATLAS_RELEASE | grep 13.` ] || [ ! -z `echo $ATLAS_RELEASE | grep 14.` ]
    then
        source $SITEROOT/AtlasOffline/$ATLAS_RELEASE/AtlasOfflineRunTime/cmt/setup.sh
        if [ ! -z $ATLAS_PRODUCTION_ARCHIVE ]
        then
            wget $ATLAS_PRODUCTION_ARCHIVE
            export ATLAS_PRODUCTION_FILE=`ls AtlasProduction*.tar.gz`
            tar xzf $ATLAS_PRODUCTION_FILE
            export CMTPATH=`ls -d $PWD/work/AtlasProduction/*`
            export MYTEMPDIR=$PWD
            cd AtlasProduction/*/AtlasProductionRunTime/cmt
            cmt config
            source setup.sh
            echo $CMTPATH
            cd $MYTEMPDIR
        fi
    fi

}

## compile the packages
athena_compile()
{
    mkdir work

    if [ ! -z $ATLAS_PRODUCTION_ARCHIVE ]
    then
        wget $ATLAS_PRODUCTION_ARCHIVE
        export ATLAS_PRODUCTION_FILE=`ls AtlasProduction*.tar.gz`
        tar xzf $ATLAS_PRODUCTION_FILE -C work
        export CMTPATH=`ls -d $PWD/work/AtlasProduction/*`
        export MYTEMPDIR=$PWD
        cd work/AtlasProduction/*/AtlasProductionRunTime/cmt
        cmt config
        source setup.sh
        echo $CMTPATH
        cd $MYTEMPDIR
    fi

    if [ ! -z $GROUP_AREA_REMOTE ] ; then
        echo "Fetching group area tarball $GROUP_AREA_REMOTE..."
        wget $GROUP_AREA_REMOTE
        FILENAME=`echo ${GROUP_AREA_REMOTE} | sed -e 's/.*\///'`
        tar xzf $FILENAME -C work
        NUMFILES=`ls work | wc -l`
        DIRNAME=`ls work`
        if [ $NUMFILES -eq 1 ]
        then
	        mv work/$DIRNAME/* work
	        rmdir work/$DIRNAME
        else
	        echo 'no group area clean up necessary'
        fi
    elif [ ! -z $GROUP_AREA ]
    then
        tar xzf $GROUP_AREA -C work
    fi
    tar xzf $USER_AREA -C work
    cd work
    pwd
    source install.sh; echo $? > retcode.tmp
    retcode=`cat retcode.tmp`
    rm -f retcode.tmp
    if [ $retcode -ne 0 ]; then
        echo "*************************************************************"
        echo "*** Compilation warnings. Return Code $retcode            ***"
        echo "*************************************************************"
    fi
    pwd
    cd ..
 
}
