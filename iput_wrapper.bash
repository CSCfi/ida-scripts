#!/bin/bash

# Wrapper for transfering files using iput for iRODS 4.X.X clients.
# Handles logging, checksum/size checking, iput 'large file retries', wildcards,
# deep directory creation, skipping existing files (when checksums and sizes match),
# skipping existing directories, etc.
#
# The purpose is to:
#  1) Imitate irsync, which is buggy and missing most of the features of iput
#  2) Create detailed log entries of transfers (creation of directories,
#     individual file transfer errors, checksum comparisons)
#  3) Force users to use best practices when tranferring files (avoid using
#     recursive transfers, compare checksums, etc.)
#  4) Help in transferring large directories
#  5) Provide iRODS operators better logging for debugging user file
#     transfers assuming users remember/are able to use the wrappper and
#     are able to provide the transfer logs
#
# Taneli Riitaoja 2015-2016 / CSC - IT Center for Science Ltd.
#
#
# Note: Change the variables in the "User settings" section to suit your needs
#       Also change "PREFERRED_HASH" to suit your needs.
#

# Save args
ARGS="$@"

# Set debugging pretty print
export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

# Debug
# (Don't change this, set it with a command line option)
DEBUG=false

# Dry run
# (Don't change this, set it with a command line option)
DRY_RUN=false

# Automatically confirm user prompt
# (Don't change this, set it with a command line option)
CONFIRM=false

# Allow wildcards (GLOB) in local path
GLOB=false

# Initialize paths
PATH="$PATH:/usr/local/bin:/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin"
BASEDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Placeholder for lfrestart file identifier
identifier="#identifier#"

# Lists to keep track of transfer results
OK_TRANSFERS=()
FAILED_TRANSFERS=()
SKIPPED_TRANSFERS=()

# ========== START User settings ==========
ZONE="ida" # iRODS zone
PORT="1247"
# PORT="1247|202[0-9]{3}"
POTENTIAL_HOSTS="86.50.24.24[0-5]|86.50.24.19[5-8]|86.50.24.20[3-4]" # Regexp for host candidates for $ZONE
NETSTAT_TEMP="${BASEDIR}/${ZONE}_tmp_netstat.txt" > "$NETSTAT_TEMP"
LOGFILE="${BASEDIR}/${ZONE}_transfer.log"
DEBUGLOGFILE="${BASEDIR}/${ZONE}_transfer_debug.log"
LFRESTART_TEMPLATE="${BASEDIR}/iput_lfrestart_file"
# Note: Threads set to 1, so iRODS cli uses only 1247 port (no high ports like
# 20000:20200) to get around "smart" firewall/NAT problems. If you change this,
# be sure to also change the PORT value
IPUT_OPTS="-N 0 -T --lfrestart ${LFRESTART_TEMPLATE}_${identifier} --retries 3"
# ==========  END User settings  ==========


# Pre-flight check

# Check existence of necessary non-basic commands
unameout=`uname -a`
os=`uname`
case "$os" in
	Darwin) required_cmds=( "iquest" "irm" "imkdir" "iput" "ienv" "imiscsvrinfo" "iuserinfo" "shasum" "md5" "xxd" "base64" "netstat" "diff" )
		SHA_PROG='shasum -a 256'
		MD5_PROG='md5'
        STAT='stat -f %z'
		;;
	*) required_cmds=( "iquest" "irm" "imkdir" "iput" "ienv" "imiscsvrinfo" "iuserinfo" "sha256sum" "md5sum" "xxd" "base64" "netstat" "diff" )
		SHA_PROG='sha256sum'
		MD5_PROG='md5sum'
        STAT='stat -c %s'
		;;
esac
for req_cmd in "${required_cmds[@]}"
do
    cmd_loc=""
    cmd_loc=`/usr/bin/which "$req_cmd"`
    if [[ ! -e "$cmd_loc" ]]
    then
        echo "ERROR: Couldn't find $req_cmd. Modify \$PATH to include the directory it is located in: $PATH"
        exit 1
    fi
done

# User setting: Choose whether to use SHA256 or MD5
PREFERRED_HASH="$SHA_PROG"

# Check irods cli version
iversion=`ienv | grep -e "Release Version" -e "irods_version" | awk -F"rods" '{ print $2 }' | awk -F"," '{ print $1 }'`
if ! [[ "$iversion" =~ 4.[0-9].[0-9] ]]
then
    echo "ERROR: iRODS cli version is $iversion. Please upgrade to iRODS cli 4.X (http://irods.org/download)"
    exit 1
fi

# Check we are connected to $ZONE
icd "/$ZONE"
cmd_status="$?"

if [[ "$cmd_status" != "0" ]]
then
    echo "ERROR: You need to be connected to $ZONE. Please issue the command 'iinit' to get started"
    exit 1
fi

# Check the iRODS username
irods_username=`iuserinfo | grep "name:" | awk -F"name: " '{ print $2 }'`

# Store the address we are connecting to
irods_server=`ienv | grep irods_host | awk -F"irods_host - " '{ print $2 }'`

# Check for write access to $BASEDIR
touch "${BASEDIR:?}/temp_touch_test.txt"
cmd_status="$?"

if [[ "$cmd_status" != "0" ]]
then
    echo "ERROR: ${BASH_SOURCE} needs write access to $BASEDIR for creating temporary files"
    exit 1
else
    /bin/rm "${BASEDIR:?}/temp_touch_test.txt"
fi

# Functions

# Create a directory (with parent directories if needed) in iRODS if the
# directory does not exist
# $1: Absolute iRODS path of the directory without trailing slashes
# $2: 0 for regular imkdir, 1 for imkdir with -p switch
function createIdaPath()
{
    if [[ -z "$1" ]] || [[ -z "$2" ]]
    then
        echo "ERROR CREATING DIR (exit): $create_irods_path" | tee -a "$LOGFILE"
        exit 1
    fi

    create_irods_path="$1"

    if [[ "$DRY_RUN" == false ]]
    then
        if [[ "$2" == "0" ]]
        then
            imkdir_out=$(imkdir "$create_irods_path" 2>&1 >/dev/null)
        else
            imkdir_out=$(imkdir -p "$create_irods_path" 2>&1 >/dev/null)
        fi
    else
        echo "DRY RUN: Faking creating $create_irods_path directory" | tee -a "$LOGFILE"
    fi
    cmd_status="$?"

    if [[ "$cmd_status" == "0" ]]
    then
        if [[ "$2" == "0" ]]
        then
            echo "CREATED DIR: $create_irods_path" | tee -a "$LOGFILE"
        fi
    else
        if [[ "$imkdir_out" == *"CATALOG_ALREADY_HAS_ITEM_BY_THAT_NAME"* ]]
        then
            echo "DIR EXISTS: $create_irods_path" | tee -a "$LOGFILE"
        else
            echo "ERROR CREATING DIR (exit): $create_irods_path" | tee -a "$LOGFILE"
            exit 1
        fi
    fi
}

# Transfer a single file to iRODS
# $1: Relative local filepath
function transferFile ()
{
    relative_local_filepath="$1"

    # CONSTRUCT PATHS

    # File name, example: testfile.dat
    data_name=${relative_local_filepath##*/}

    # fdir: Relative iRODS directory, example: testdatadir
    if [[ "$SOURCE_IS_FILE" == false ]]
    then
        # If source is a directory, the file to be transferred has a relative directory
        fdir=${relative_local_filepath%/*}

        if [[ "$data_name" == "$fdir" ]] || [[ "$fdir" == "/" ]] || [[ -z "$fdir" ]]
        then
            # ... except in special cases
            fdir=""
        fi
    else
        # If source is a file, the file to be transferred doesn't have a relative directory
        fdir=""
    fi

    # iRODS directory name where the file (will) reside, example: /ida/organization/project/testdatadir
    coll_name="${TARGET_PATH}${fdir}"

    # Full local path, example: /home/user/testdatadir/testfile.dat
    local_full_source_path="${SOURCE_PATH}${relative_local_filepath}"
    # Full iRODS path, example: /ida/organization/project/testdatadir/testfile.dat
    irods_target_path="${TARGET_PATH}${fdir}/${data_name}"

    # CALCULATE LOCAL FILE SIZE                                                 
    local_size=`${STAT} ${local_full_source_path}`     

    # INVESTIGATE CHECKSUMS

    # If local size is 0 bytes, skip checksums
    # Note: replicas are compared against each other. Even when using restart files and resuming the tranfer, the _replicas_ should
    # be identical. If not, something has gone wrong with iRODS replication process (not the server-client transfer)
    # Check whether the file exists. If it exists, save the iRODS checksum and size
    iqout=`iquest --no-page "%s/%s###%s###%s" "SELECT COLL_NAME, DATA_NAME, DATA_CHECKSUM, DATA_SIZE WHERE COLL_NAME = '${coll_name}' AND DATA_NAME = '${data_name}'" 2> /dev/null`
    iqout_unique_count=`echo "$iqout" | uniq | wc -l`
    # Check if either sizes or checksums of replicas don't match
    if [[ "$iqout_unique_count" -gt "1" ]] 
    then
        echo "NOTE MISMATCHING REPLICAS OR SIZE IN $ZONE: ${irods_target_path}" | tee -a "$LOGFILE"
        echo "$iqout" | tee -a "$LOGFILE"
        echo "Removing both replicas for ${irods_target_path} before attempting transfer" | tee -a "$LOGFILE"
        irm -f "${irods_target_path:?}"
        cmd_status="$?"
        if [[ "$cmd_status" != "0" ]]
        then
            echo "Removing both existing replicas failed. Failed to transfer ${irods_target_path}" | tee -a "$LOGFILE"
            FAILED_TRANSFERS=("${FAILED_TRANSFERS[@]}" "$irods_target_path")
            return
        else
            echo "Successfully removed both existing replicas" | tee -a "$LOGFILE"
        fi
    fi

    if [[ "$iqout" != *"/${ZONE}"* ]]
    then
        irods_sum=""
        irods_size=""
    else
        irods_sum=`echo "$iqout" | awk -F"###" '{ print $2 }' | awk -F"sha2:" '{ print $2 }'`
        irods_size=`echo "$iqout" | awk -F"###" '{ print $3 }'`
    fi

    # Calculate a local checksum for the file, skip if size of local file is 0 bytes
    if [[ "$DRY_RUN" == false ]]
    then
        local_checksum=`${PREFERRED_HASH} ${local_full_source_path} | awk '{ print $1 }' | xxd -r -p | base64`

        # Create an identifier for the restart files (unique (or close enough) for non-empty files)
        # MD5 used for identifier because: faster to calculate, doesn't contain funny characters
        identifier=`echo "$local_checksum" | ${MD5_PROG} | awk '{ print $1 }'`

        # Compare the local checksum to the iRODS checksum
        if [[ "$local_checksum" != "$irods_sum" ]] || [[ "$local_size" != "$irods_size" ]]
        then
            # Always overwrite the iRODS file if checksums or size differs (the file either doesn't exist in iRODS or it differs)
             iput_o=`echo "-f $IPUT_OPTS" | sed "s/\#identifier\#/${identifier}/g"`
        elif [[ "$local_checksum" == "$irods_sum" ]] && [[ "$local_size" == "$irods_size" ]]
        then
            echo "SKIP: ${irods_target_path}"  | tee -a "$LOGFILE"
            echo "OK CHECK: LOCAL: $local_checksum $ZONE: ${irods_sum}" | tee -a "$LOGFILE"
            SKIPPED_TRANSFERS=("${SKIPPED_TRANSFERS[@]}" "$irods_target_path")
            return
        elif [[ -z "$local_checksum" ]] || [[ -z "$local_size" ]] 
        then
            echo "FAIL LOCAL CHECKSUM OR SIZE: ${local_full_source_path}"
        fi
    else
        echo "DRY RUN: Faking comparing checksums" | tee -a "$LOGFILE"
    fi

    # TRANSFER THE FILE

    # Actual transfer
    actual_server=""
    echo "${local_full_source_path}  ----->  ${irods_target_path}" 
    if [[ "$DRY_RUN" == false ]]
    then
        # Regarding netstat...
        netstat -n | egrep "$POTENTIAL_HOSTS" | awk '{ print $4, $5 }' | egrep "$PORT" > "$NETSTAT_TEMP"
        iput $iput_o "${local_full_source_path}" "${irods_target_path}"
        cmd_status="$?"
        # ...for debug purposes use netstat to find out the _actual_ server to which iput transfers files.
        # The actual server might differ from the irods_host address if the irods_host address
        # is a virtual IP, or if the connection is handed elsewhere on the server side
        netstat_after=`netstat -n | egrep "$POTENTIAL_HOSTS" | awk '{ print $4, $5 }' | egrep "$PORT"`
        actual_server=`echo "$netstat_after" | diff -u - "$NETSTAT_TEMP" | egrep "^\-[0-9]" | awk '{ print $2 }'`
    else
        echo "DRY RUN: Faking transferring file" | tee -a "$LOGFILE"
        # Echo is always OK
        cmd_status="$?" 
    fi


    # CHECK TRANSFER RESULT

    # Check whether the transfer succeeded, skip if size of local file is 0 bytes
    if [[ "$cmd_status" == "0" ]]
    then
        if [[ "$local_size" != "0" ]]
        then
            if [[ "$DRY_RUN" == false ]]
            then
                # Check the current checksum of the file in iRODS
                iqout=`iquest --no-page "%s###%s" "SELECT DATA_CHECKSUM, DATA_SIZE WHERE COLL_NAME = '${coll_name}' AND DATA_NAME = '${data_name}'" | awk -F":" '{ print $2 }' 2> /dev/null`
                iqout_unique_count=`echo "$iqout" | uniq | wc -l`
                # Check if either sizes or checksums of replicas don't match
                if [[ "$iqout_unique_count" -gt "1" ]]
                then
                    echo "FAIL MISMATCHING REPLICAS OR SIZES IN $ZONE: ${irods_target_path}" | tee -a "$LOGFILE"
                    echo "$iqout" | tee -a "$LOGFILE"
                    FAILED_TRANSFERS=("${FAILED_TRANSFERS[@]}" "$irods_target_path")
                else
                    irods_sum_new=`echo "$iqout" | awk -F"###" '{ print $1 }'`
                    irods_size_new=`echo "$iqout" | awk -F"###" '{ print $2 }'`
                    # If the sizes and checksums match, the transfer was OK. The restart file templates can be cleaned.
                    if [[ "$irods_size_new" == "$local_size" ]]
                    then
                        echo "OK SIZE: LOCAL: $local_size $ZONE: ${irods_size_new}" | tee -a "$LOGFILE"
                        if [[ "$irods_sum_new" == "$local_checksum" ]]
                        then
                            echo "OK CHECK LOCAL: $local_checksum $ZONE: ${irods_sum_new}" | tee -a "$LOGFILE"
                            echo "OK: ${irods_target_path} ($actual_server)" | tee -a "$LOGFILE"
                            OK_TRANSFERS=("${OK_TRANSFERS[@]}" "$irods_target_path")
                        else
                            echo "FAIL CHECK LOCAL: $local_checksum $ZONE: ${irods_sum_new}" | tee -a "$LOGFILE"
                            echo "FAIL: ${irods_target_path} ($actual_server)" | tee -a "$LOGFILE"
                            FAILED_TRANSFERS=("${FAILED_TRANSFERS[@]}" "$irods_target_path")
                        fi
                    else
                        echo "FAIL SIZE: LOCAL: $local_size $ZONE: ${irods_size_new}" | tee -a "$LOGFILE"
                        if [[ "$irods_sum_new" == "$local_checksum" ]]
                        then
                            echo "OK CHECK LOCAL: $local_checksum $ZONE: ${irods_sum_new}" | tee -a "$LOGFILE"
                        else
                            echo "FAIL CHECK LOCAL: $local_checksum $ZONE: ${irods_sum_new}" | tee -a "$LOGFILE"
                        fi
                        echo "FAIL: ${irods_target_path} ($actual_server)" | tee -a "$LOGFILE"
                        FAILED_TRANSFERS=("${FAILED_TRANSFERS[@]}" "$irods_target_path")

                    fi
                fi
            else
                echo "DRY RUN: Not checking for transferred file checksums" | tee -a "$LOGFILE"
            fi
        else
            echo "OK: Tranferred 0 bytes sized file to iRODS: not comparing checksums or sizes" | tee -a "$LOGFILE"
            echo "OK: ${irods_target_path} ($actual_server)" | tee -a "$LOGFILE"
            OK_TRANSFERS=("${OK_TRANSFERS[@]}" "$irods_target_path")
        fi
    else
        echo "FAIL: ${irods_target_path} ($actual_server)" | tee -a "$LOGFILE"
        FAILED_TRANSFERS=("${FAILED_TRANSFERS[@]}" "$irods_target_path")
    fi
}

# Ask the user for confirmation before beginning transfer
function userConfirm ()
{
    subdir_amount="$1"
    file_amount="$2"
    single_file="$3"

    echo "$irods_username : $iversion : $irods_server : $unameout" | tee -a "$LOGFILE"

    if [[ "$SOURCE_IS_FILE" == false ]]
    then
        echo "You are attempting to transfer the _contents_ of the following local directory:"
        echo -e "\n${SOURCE_PATH}\n"  | tee -a "$LOGFILE"
    else
        echo "You are attempting to transfer the following local file:"
        echo -e "\n${single_file}\n"  | tee -a "$LOGFILE"
    fi

    echo "The target directory of the transfer in $ZONE is the following directory:"
    echo -e "\n$TARGET_PATH\n"  | tee -a "$LOGFILE"

    if [[ "$SOURCE_IS_FILE" == false ]]
    then
        echo "Amount of subdirectories to transfer: $subdir_amount" | tee -a "$LOGFILE"
    fi

    echo "Amount of files to transfer: $file_amount" | tee -a "$LOGFILE"

    if [[ "$file_amount" -gt "1000" ]]
    then
        echo "You are attempting to transfer over 1000 files! It might be prudent to create a 'tar' package of the files instead" | tee -a "$LOGFILE"
    fi

    echo "Logfile will be generated at: $LOGFILE" | tee -a "$LOGFILE"

    if ! [[ "$DRY_RUN" == false ]]
    then
        echo "DRY RUN: No actual directories will be created or files transferred"
    fi 

    if [[ "$CONFIRM" == true ]]
    then
        return
    fi

    read -p "Are you sure? Y/N  " -r
    echo 
    if [[ ! $REPLY =~ ^[Yy]$ ]]
    then
        bailout
    fi
}

# Main
function transferMain ()
{
    # Main
    # Check if the source path is a directory or a single file or a wildcarded path
    if [[ "$GLOB" == true ]]
    then
        source_dirs=""
        source_dir_path=${SOURCE_PATH%/*} 
        source_files=`find "$source_dir_path" -type f -path "$SOURCE_PATH" | sed "s|${source_dir_path}||" | sed 's/^\.\///'`
        SOURCE_PATH="$source_dir_path"
    elif [[ "$SOURCE_IS_FILE" == false ]]
    then
        # Create a list of directories and subdirectories in the source path, with relative paths
        source_dirs=`find "$SOURCE_PATH" -type d | sed "s|${SOURCE_PATH}||" | sed 's/^\.\///' | tail -n +2`
        # Create a list of files in the source path, with relative paths
        source_files=`find "$SOURCE_PATH" -type f | sed "s|${SOURCE_PATH}||" | sed 's/^\.\///'`
    elif [[ "$SOURCE_IS_FILE" == true ]]
    then
        # Source is a single file
        source_dirs=""
        if [[ "${SOURCE_PATH}" == /* ]]
        then
            # SOURCE_PATH is absolute filepath
            source_files="/${SOURCE_PATH##*/}"
            SOURCE_PATH=${SOURCE_PATH%/*}
        else
            # SOURCE_PATH is relative filepath
            source_files="${SOURCE_PATH}"
            SOURCE_PATH=""
        fi
    fi

    if [[ -z "$source_dirs" ]]
    then
        amount_dirs="0"
    else
        amount_dirs=`echo "$source_dirs" | wc -l`
    fi

    if [[ -z "$source_files" ]]
    then
        amount_files="0"
    else
        amount_files=`echo "$source_files" | wc -l`
    fi

    if [[ "$amount_files" == "0" ]] && [[ "$amount_dirs" == "0" ]]
    then
        echo "The local directory contains no directories or files to transfer!"
        bailout
    fi

    # Get user confirmation for the transfer
    userConfirm "$amount_dirs" "$amount_files" "$source_files"
    
    # Create the iRODS target path if necessary
    createIdaPath "$TARGET_PATH" "1"
    
    # Create iRODS directories and subdirectories under the target path
    # to match the source path directory structure
    if [[ "$SOURCE_IS_FILE" == false ]]
    then
        # Only create those subdirectories that do not exist
        all_subdirectories=`iquest --no-page "%s" "SELECT COLL_NAME WHERE COLL_NAME LIKE '${TARGET_PATH}%'"`
        while read subdir
        do
            subdir_match=`echo "$all_subdirectories" | grep -x "${TARGET_PATH}${subdir}"`
            if [[ -z "$subdir_match" ]]
            then
                createIdaPath "${TARGET_PATH}${subdir}" "0"
            else
                echo "DIR EXISTS: ${TARGET_PATH}${subdir}" | tee -a "$LOGFILE"           
            fi
        done <<< "$source_dirs"
    fi
    
    # Loop for transferring files
    i="0"
    if [[ "$amount_files" != "0" ]]
    then
        while read transfer_file_path
        do
            i=$((i+1))
            start_time=`date`
            echo "START TRANSFER ($i/$amount_files): $start_time - ${SOURCE_PATH}${transfer_file_path}" | tee -a "$LOGFILE"
            transferFile "$transfer_file_path"
            end_time=`date`
            echo "END TRANSFER ($i/$amount_files): $end_time - ${SOURCE_PATH}${transfer_file_path}" | tee -a "$LOGFILE"
        done <<< "$source_files"
    fi

    # Output the results
    echo "-------------TOTAL TRANSFER STATS-------------" | tee -a "$LOGFILE"
    echo "Successfully transferred ${#OK_TRANSFERS[@]}/${amount_files} files" | tee -a "$LOGFILE"
    echo "Skipped ${#SKIPPED_TRANSFERS[@]}/${amount_files} files (checksums match, no need to transfer)" | tee -a "$LOGFILE"
    echo "Failed to transfer ${#FAILED_TRANSFERS[@]}/${amount_files} files" | tee -a "$LOGFILE"
    echo "See the log of the transfer(s): $LOGFILE" | tee -a "$LOGFILE"
    if [[ "$DEBUG" == true ]]
    then
        echo "See the debug log of the transfer(s): $DEBUGLOGFILE" | tee -a "$LOGFILE"
    fi
}
    

# Usage instructions
function usage ()
{
cat <<EOF
Wrapper script for iRODS command line client 'iput'. Imitates 'irsync'.

Arguments given for script: $ARGS

Edit script to change the iRODS zone (default: ida), iput options and log file locations

Usage: ${BASH_SOURCE[0]} [-hvd] -l "<local directory|file path>" -r "<iRODS directory>"

    -l "<local path>"       Local directory or file path (source)
                            Use quotes (") if your path contains spaces or special characters 
                            Example (directory path): "/home/user/mydirectory"
                            Example (file path): "/home/user/mydirectory2/myfile.dat"
    -r "<iRODS directory>"   IRODS directory path (target)
                            Use quotes (") if your path contains spaces or special characters 
                            Example: "/ida/organization/project/researchdata"
    -h                      This help text
    -g                      Allow using wildcards with -l (for example /home/user/mydirectory/myfile*.dat, for myfile1.dat, myfile2.dat, etc.)
                            The local path that uses wildcards must be enclosed with single quotes ('), for example:
                            -l '/home/user/mydirectory/myfile*.dat' -r /ida/organization/project/researchdata
    -v                      Verbose mode: Sets '-P' option (show progress) for iput
    -c                      Confirm the user prompt automatically (not recommended)
    -d                      Debug mode: Logs everything to $DEBUGLOGFILE
    -n                      Dry run: do not create directories or transfer files

Example:
    Command: ${BASH_SOURCE[0]} -l "/home/user/mydirectory" -r "/ida/organization/project/researchdata"
    Result: -> The iRODS directory "/ida/organization/project/researchdata" will contain all the contents of "/home/user/mydirectory"

    Command: ${BASH_SOURCE[0]} -l "/home/user/mydirectory2/myfile.dat" -r "/ida/organization/project/researchdata"
    Result: -> The file 'myfile.dat' will be transferred to "/ida/organization/project/researchdata/myfile.dat"

Log will be saved to $LOGFILE
EOF
}

function bailout ()
{
    usage
    exit 1
}

lgiven=false
rgiven=false

# Check arguments and initialize
while getopts hgvcndl:r: OPTIONS
do
    case $OPTIONS in
        h) bailout ;;
        g) GLOB=true ;;
        v) IPUT_OPTS="-P $IPUT_OPTS" ;;
        c) CONFIRM=true ;;
        n) DRY_RUN=true ;;
        d) # Set up debugging
           DEBUG=true
           IPUT_OPTS="-P $IPUT_OPTS" 
           exec > >(tee -a -i "$DEBUGLOGFILE")
           exec 2>&1
           set -x
           ;;
        l) # Check GLOB
           if [[ "$GLOB" == true ]]
           then
               SOURCE_PATH="${OPTARG}"
           else
               SOURCE_PATH="${OPTARG%/}"
           fi
           lgiven=true
           ;;
        r) TARGET_PATH=`echo ${OPTARG%/}`; rgiven=true ;;
        \?) "Option -$OPTARG not supported"; bailout ;;
        :) "Option -$OPTARG requires arguments"; bailout ;;
    esac
done

if [[ "$lgiven" == false ]] || [[ "$rgiven" == false ]]
then
    echo "ERROR: Invalid arguments given for script"
    bailout
fi

if [[ "$GLOB" == false && ! -d "$SOURCE_PATH" && ! -f "$SOURCE_PATH" ]]
then
    echo "ERROR: $SOURCE_PATH is not a directory or file"
    bailout
fi

if [[ "$GLOB" == true ]]
then
    echo "Wildcards active in local path"
elif [[ -d "$SOURCE_PATH" ]]
then
    SOURCE_IS_FILE=false
elif [[ -f "$SOURCE_PATH" ]]
then
    SOURCE_IS_FILE=true
fi

# Launch
transferMain
echo "Done"
exit 0


