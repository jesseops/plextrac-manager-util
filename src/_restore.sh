# Simple restore of backups
#
# Usage:
#   plextrac restore

function mod_restore() {
  restoreTargets=(restore_doPostgresRestore restore_doCouchbaseRestore restore_doUploadsRestore)
  currentTarget=`tr [:upper:] [:lower:] <<< "${RESTORETARGET:-ALL}"`
  for target in "${restoreTargets[@]}"; do
    debug "Checking if $target matches $currentTarget"
    if [[ $currentTarget == "all" || ${target,,} =~ "restore_do${currentTarget}restore" ]]; then
      $target
    fi
  done
}

function restore_doUploadsRestore() {
  title "Restoring uploads from backup"
  latestBackup="`ls -dc1 ${PLEXTRAC_BACKUP_PATH}/uploads/* | head -n1`"
  info "Latest backup: $latestBackup"

  error "This is a potentially destructive process, are you sure?"
  info "Please confirm before continuing the restore"

  if get_user_approval; then
    log "Restoring from $latestBackup"
    debug "`cat $latestBackup | compose_client run --workdir /usr/src/plextrac-api --rm --entrypoint='' -T \
      $coreBackendComposeService tar -xzf -`"
    log "Done"
  fi
}

function restore_doCouchbaseRestore() {
  title "Restoring Couchbase from backup"
  debug "Fixing permissions"
  debug "`compose_client exec -T $couchbaseComposeService \
    chown -R 1337:1337 /backups 2>&1`"
  latestBackup="`ls -dc1 ${PLEXTRAC_BACKUP_PATH}/couchbase/* | head -n1`"
  backupFile=`basename $latestBackup`
  info "Latest backup: $latestBackup"

  error "This is a potentially destructive process, are you sure?"
  info "Please confirm before continuing the restore"

  if get_user_approval; then
    log "Restoring from $backupFile"
    log "Extracting backup files"
    debug "`compose_client exec -T --user 1337 --workdir /backups $couchbaseComposeService \
      tar -xzvf /backups/$backupFile 2>&1`"

    log "Running database restore"
    # We have the TTY enabled by default so the output from cbrestore is intelligible
    tty -s || { debug "Disabling TTY allocation for Couchbase restore due to non-interactive invocation"; ttyFlag="-T"; }
    compose_client exec ${ttyFlag:-} $couchbaseComposeService cbrestore /backups http://localhost:8091 \
      -u ${CB_BACKUP_USER} -p "${CB_BACKUP_PASS}" --from-date 2022-01-01 -x conflict_resolve=0,data_only=1

    log "Cleaning up extracted backup files"
    dirName=`basename -s .tar.gz $backupFile`
    debug "`compose_client exec -T --user 1337 --workdir /backups $couchbaseComposeService \
      rm -rf /backups/$dirName 2>&1`"
    log "Done"
  fi
}

function restore_doPostgresRestore() {
  title "Restoring Postgres from backup"
  latestBackup="`ls -dc1 ${PLEXTRAC_BACKUP_PATH}/postgres/* | head -n1`"
  backupFile=`basename $latestBackup`
  info "Latest backup: $latestBackup"

  error "This is a potentially destructive process, are you sure?"
  info "Please confirm before continuing the restore"

  if get_user_approval; then
    databaseBackups=$(basename -s .psql `tar -tf $latestBackup | awk '/.psql/{print $1}'`)
    log "Restoring from $backupFile"
    log "Databases to restore:\n$databaseBackups"
      debug "`compose_client exec -T --user 1337 $postgresComposeService\
        tar -tf /backups/$backupFile 2>&1`"
    for db in $databaseBackups; do
      log "Extracting backup for $db"
      debug "`compose_client exec -T $postgresComposeService\
        tar -xvzf /backups/$backupFile ./$db.psql 2>&1`"
      dbAdminEnvvar="PG_${db^^}_ADMIN_USER"
      dbAdminRole=$(eval echo "\$$dbAdminEnvvar")
      log "Restoring $db with role:${dbAdminRole}"
      dbRestoreFlags="-d $db --clean --if-exists --no-privileges --no-owner --role=$dbAdminRole  --disable-triggers --verbose"
      debug "`compose_client exec -T -e PGPASSWORD=$POSTGRES_PASSWORD $postgresComposeService \
        pg_restore -U $POSTGRES_USER $dbRestoreFlags ./$db.psql 2>&1`"
      debug "`compose_client exec -T $postgresComposeService \
        rm ./$db.psql 2>&1`"
    done
  fi
}
