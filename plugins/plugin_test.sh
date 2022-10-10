#!/bin/bash
set -e
set -o pipefail

plugin=$1
plugin_config=$2
secondary_plugin_config=$3
MINIMUM_API_VERSION="0.3.0"

# ----------------------------------------------
# Test suite setup
# This will put small amounts of data in the
# plugin destination location
# ----------------------------------------------
if [ $# -lt 2 ] || [ $# -gt 3 ]
  then
    echo "Usage: plugin_test.sh [path_to_executable] [plugin_config] [optional_config_for_secondary_destination]"
    exit 1
fi

if [[ "$plugin_config" != /* ]] ; then
    echo "Must provide an absolute path to the plugin config"
    exit 1
fi

# This should be time_second=$(date +"%Y%m%d%H%M%S") but concurrent
# runs require randomness to ensure they don't collide with each other
# in writing/deleting backups. We ensure there are 14 characters
# through the expression below.
time_second=$(expr 99999999999999 - $(od -vAn -N5 -tu < /dev/urandom | tr -d ' \n'))
current_date=$(echo $time_second | cut -c 1-8)

testdir="/tmp/testseg/backups/${current_date}/${time_second}"
testfile="$testdir/testfile_$time_second.txt"
testdata="$testdir/testdata_$time_second.txt"
test_no_data="$testdir/test_no_data_$time_second.txt"
testdatasmall="$testdir/testdatasmall_$time_second.txt"
testdatalarge="$testdir/testdatalarge_$time_second.txt"

logdir="/tmp/test_bench_logs"

text="this is some text"
data=`LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 1000 ; echo`
data_large=`LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 1000000 ; echo`
mkdir -p $testdir
mkdir -p $logdir
echo $text > $testfile

# ----------------------------------------------
# Cleanup functions
# ----------------------------------------------
cleanup_test_dir() {
  if [ $# -ne 1 ]
  then
    echo "Must call cleanup_test_dir with only 1 argument"
    exit 1
  fi

  testdir_to_clean=$1

  $plugin cleanup_plugin_for_backup $plugin_config $testdir_to_clean master \"-1\"
  $plugin cleanup_plugin_for_backup $plugin_config $testdir_to_clean segment_host
  $plugin cleanup_plugin_for_backup $plugin_config $testdir_to_clean segment \"0\"
  echo "[PASSED - CLEANUP] cleanup_plugin_for_backup"

  $plugin cleanup_plugin_for_restore $plugin_config $testdir_to_clean master \"-1\"
  $plugin cleanup_plugin_for_restore $plugin_config $testdir_to_clean segment_host
  $plugin cleanup_plugin_for_restore $plugin_config $testdir_to_clean segment \"0\"
  echo "[PASSED - CLEANUP] cleanup_plugin_for_restore"
}

echo "# ----------------------------------------------"
echo "# Starting gpbackup plugin tests"
echo "# ----------------------------------------------"

# ----------------------------------------------
# Check API version
# ----------------------------------------------

echo "[RUNNING] plugin_api_version"
api_version=`$plugin plugin_api_version`
# `awk` call returns 1 for true, 0 for false (contrary to bash logic)
if (( 0 == $(echo "$MINIMUM_API_VERSION $api_version" | awk '{print ($1 <= $2)}') )) ; then
  echo "Plugin API version is less than the minimum supported version $MINIMUM_API_VERSION"
  exit 1
fi
echo "[PASSED] plugin_api_version"

echo "[RUNNING] --version"
native_version=`$plugin --version`
echo "$native_version" | grep --regexp '.* version .*' > /dev/null 2>&1
if [[ ! $? -eq 0 ]]; then
  echo "Plugin --version is not in expected format of <plugin name> version <version>"
  exit 1
fi
echo "[PASSED] --version"

# ----------------------------------------------
# Setup and Backup/Restore file functions
# ----------------------------------------------

echo "[RUNNING] setup_plugin_for_backup on master"
$plugin setup_plugin_for_backup $plugin_config $testdir master \"-1\"
echo "[RUNNING] setup_plugin_for_backup on segment_host"
$plugin setup_plugin_for_backup $plugin_config $testdir segment_host
echo "[RUNNING] setup_plugin_for_backup on segment 0"
$plugin setup_plugin_for_backup $plugin_config $testdir segment \"0\"

echo "[RUNNING] backup_file"
$plugin backup_file $plugin_config $testfile
# plugins should leave copies of the files locally when they run backup_file
test -f $testfile

echo "[RUNNING] setup_plugin_for_restore on master"
$plugin setup_plugin_for_restore $plugin_config $testdir master \"-1\"
echo "[RUNNING] setup_plugin_for_restore on segment_host"
$plugin setup_plugin_for_restore $plugin_config $testdir segment_host
echo "[RUNNING] setup_plugin_for_restore on segment 0"
$plugin setup_plugin_for_restore $plugin_config $testdir segment \"0\"

echo "[RUNNING] restore_file"
rm $testfile
$plugin restore_file $plugin_config $testfile
output=`cat $testfile`
if [ "$output" != "$text" ]; then
  echo "Failed to backup and restore file using plugin"
  exit 1
fi

echo "[RUNNING] attempting to restore_file of non-existent file should fail"
set +e
$plugin restore_file $plugin_config "$testdir/there_is_no_file_to_restore" > /dev/null 2>&1
nonexist_file_restore=$(echo $?)
set -e
if [ "$nonexist_file_restore" == "0" ]; then
  echo "Failed, when trying to restore a file that does not exist, should have error"
  exit 1
fi


if [[ "$plugin_config" == *ddboost_config_replication.yaml ]] && [[ -n "$secondary_plugin_config" ]]; then
  rm $testfile
  echo "[RUNNING] restore_file (from secondary destination)"
  $plugin restore_file $secondary_plugin_config $testfile
  output=`cat $testfile`
  if [ "$output" != "$text" ]; then
    echo "Failed to backup and restore file using plugin from secondary destination"
    exit 1
  fi
fi
echo "[PASSED] setup_plugin_for_backup"
echo "[PASSED] backup_file"
echo "[PASSED] setup_plugin_for_restore"
echo "[PASSED] restore_file"
cleanup_test_dir $testdir

# ----------------------------------------------
# Backup/Restore data functions
# ----------------------------------------------

echo "[RUNNING] backup_data"
echo $data | $plugin backup_data $plugin_config $testdata
echo "[RUNNING] restore_data"
output=`$plugin restore_data $plugin_config $testdata`

if [ "$output" != "$data" ]; then
  echo "Failed to backup and restore data using plugin"
  exit 1
fi

if [[ "$plugin_config" == *ddboost_config_replication.yaml ]] && [[ -n "$secondary_plugin_config" ]]; then
  echo "[RUNNING] restore_data (from secondary destination)"
  output=`$plugin restore_data $secondary_plugin_config $testdata`

  if [ "$output" != "$data" ]; then
    echo "Failed to backup and restore data using plugin"
    exit 1
  fi
fi
echo "[PASSED] backup_data"
echo "[PASSED] restore_data"
cleanup_test_dir $testdir

echo "[RUNNING] backup_data with no data"
echo -n "" | $plugin backup_data $plugin_config $test_no_data
echo "[RUNNING] restore_data with no data"
output=`$plugin restore_data $plugin_config $test_no_data`

if [ "$output" != "" ]; then
  echo "Failed to backup and restore data using plugin"
  exit 1
fi

if [[ "$plugin_config" == *ddboost_config_replication.yaml ]] && [[ -n "$secondary_plugin_config" ]]; then
  echo "[RUNNING] restore_data with no data (from secondary destination)"
  output=`$plugin restore_data $secondary_plugin_config $test_no_data`

  if [ "$output" != "" ]; then
    echo "Failed to backup and restore data using plugin"
    exit 1
  fi
fi
echo "[PASSED] backup_data with no data"
echo "[PASSED] restore_data with no data"
cleanup_test_dir $testdir

# ----------------------------------------------
# Run test gpbackup and gprestore with plugin
# ----------------------------------------------
#gpbackup --dbname $test_db --plugin-config $plugin_config $further_options > $log_file

test_backup_and_restore_with_plugin() {
    flags=$1
    restore_filter=$2
    test_db=plugin_test_db
    log_file="$logdir/plugin_test_log_file"

    psql -X -d postgres -qc "DROP DATABASE IF EXISTS $test_db" 2>/dev/null
    createdb $test_db
    psql -X -d $test_db -qc "CREATE TABLE test1(i int) DISTRIBUTED RANDOMLY; INSERT INTO test1 select generate_series(1,50000)"
    if [ "$restore_filter" == "restore-filter" ] ; then
      psql -X -d $test_db -qc "CREATE TABLE test2(i int) DISTRIBUTED RANDOMLY; INSERT INTO test2 VALUES(3333)"
      flags_restore="--include-table public.test2"
    fi

    set +e
    # save the encrypt key file, if it exists
    if [ -f "$MASTER_DATA_DIRECTORY/.encrypt" ] ; then
        mv $MASTER_DATA_DIRECTORY/.encrypt /tmp/.encrypt_saved
    fi
    echo "gpbackup_ddboost_plugin: 66706c6c6e677a6965796f68343365303133336f6c73366b316868326764" > $MASTER_DATA_DIRECTORY/.encrypt

    echo "[RUNNING] gpbackup with test database (using ${flags} ${flags_restore})"
    gpbackup --dbname $test_db --plugin-config $plugin_config $flags &> $log_file
    if [ ! $? -eq 0 ]; then
        echo
        cat $log_file
        echo
        echo "gpbackup failed. Check gpbackup log file in ~/gpAdminLogs for details."
        exit 1
    fi
    timestamp=`head -10 $log_file | grep "Backup Timestamp " | grep -Eo "[[:digit:]]{14}"`
    dropdb $test_db

    echo "[RUNNING] gprestore with test database"
    gprestore --timestamp $timestamp --plugin-config $plugin_config --create-db $flags_restore &> $log_file
    if [ ! $? -eq 0 ]; then
        echo
        cat $log_file
        echo
        echo "gprestore failed. Check gprestore log file in ~/gpAdminLogs for details."
        exit 1
    fi

    if [ "$restore_filter" == "restore-filter" ] ; then
      result=`psql -X -d $test_db -tc "SELECT table_name FROM information_schema.tables WHERE table_schema='public'" | xargs`
      if [ "$result" == *"test1"* ]; then
          echo "Expected relation test1 to not exist"
          exit 1
      fi
      result=`psql -X -d $test_db -tc "SELECT * FROM test2" | xargs`
      if [ "$flags" != "--metadata-only" ] && [ "$result" != "3333" ]; then
          echo "Expected relation test2 value: 3333, got %result"
          exit 1
      fi
    else
      result=`psql -X -d $test_db -tc "SELECT count(*) FROM test1" | xargs`
      if [ "$flags" != "--metadata-only" ] && [ "$result" != "50000" ]; then
          echo "Expected to restore 50000 rows, got $result"
          exit 1
      fi
    fi

    if [[ "$plugin_config" == *ddboost_config_replication.yaml ]] && [[ -n "$secondary_plugin_config" ]]; then
        dropdb $test_db
        echo "[RUNNING] gprestore with test database from secondary destination"
        gprestore --timestamp $timestamp --plugin-config $secondary_plugin_config --create-db &> $log_file
        if [ ! $? -eq 0 ]; then
            echo
            cat $log_file
            echo
            echo "gprestore from secondary destination failed. Check gprestore log file in ~/gpAdminLogs for details."
            exit 1
        fi
        result=`psql -X -d $test_db -tc "SELECT count(*) FROM test1" | xargs`
        if [ "$flags" != "--metadata-only" ] && [ "$result" != "50000" ]; then
          echo "Expected to restore 50000 rows, got $result"
          exit 1
        fi
    fi
    # replace the encrypt key file to its proper location
    if [ -f "/tmp/.encrypt_saved" ] ; then
        mv /tmp/.encrypt_saved $MASTER_DATA_DIRECTORY/.encrypt
    fi
    set -e
    echo "[PASSED] gpbackup and gprestore (using ${flags})"
}

test_backup_and_restore_with_plugin "--single-data-file --no-compression --copy-queue-size 4" "--copy-queue-size 4"
test_backup_and_restore_with_plugin "--no-compression --single-data-file"
test_backup_and_restore_with_plugin "--no-compression"
test_backup_and_restore_with_plugin "--metadata-only"
test_backup_and_restore_with_plugin "--no-compression --single-data-file" "restore-filter"


# ----------------------------------------------
# Cleanup test artifacts
# ----------------------------------------------
echo "Cleaning up leftover test artifacts"

dropdb $test_db
rm -r $logdir
rm -r /tmp/testseg

if (( 1 == $(echo "0.4.0 $api_version" | awk '{print ($1 > $2)}') )) ; then
  echo "[SKIPPING] cleanup of uploaded test artifacts using plugins (only compatible with version >= 0.4.0)"
else
  $plugin delete_backup $plugin_config $time_second
fi

echo "# ----------------------------------------------"
echo "# Finished gpbackup plugin tests"
echo "# ----------------------------------------------"
