#!/bin/bash

BLOCK_HEIGHT=$(cat /snapshot-cache-volume/BLOCK_HEIGHT)
BLOCK_HASH=$(cat /snapshot-cache-volume/BLOCK_HASH)
BLOCK_TIMESTAMP=$(cat /snapshot-cache-volume/BLOCK_TIMESTAMP)
TEZOS_VERSION=$(cat /snapshot-cache-volume/TEZOS_VERSION)
NETWORK="${NAMESPACE%%-*}"
S3_BUCKET="${NETWORK}.xtz-shots.io"

cd /

# If block_height is not set than init container failed, exit this container
[ -z "${BLOCK_HEIGHT}" ] && exit 1

printf "%s BLOCK_HASH is...$(cat /snapshot-cache-volume/BLOCK_HASH))\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
printf "%s BLOCK_HEIGHT is...$(cat /snapshot-cache-volume/BLOCK_HEIGHT)\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
printf "%s BLOCK_TIMESTAMP is...$(cat /snapshot-cache-volume/BLOCK_TIMESTAMP)\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"

# Download base.json or create if if it doesn't exist
if ! aws s3api head-object --bucket "${S3_BUCKET}" --key "base.json" > /dev/null; then
    printf "%s Check base.json : Did not detect in S3.  Creating base.json locally to append and upload later.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    if ! touch base.json; then
        printf "%s Create base.json : Error creating file base.json locally. \n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    else
        printf "%s Create base.json : Created file base.json. \n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    fi
else
    printf "%s Check base.json : Exists in S3.  Downloading to append new information and will upload later. \n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    if ! aws s3 cp s3://"${S3_BUCKET}"/base.json base.json > /dev/null; then
        printf "%s Download base.json : Error downloading file base.json from S3. \n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    else
        printf "%s Download base.json : Downloaded file base.json from S3. \n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    fi
fi

# Check if base.json exists locally
if test -f base.json; then
    printf "%s Check base.json : File base.json exists locally. \n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    # Write empty array if empty
    if ! [ -s "base.json" ]
    then
    # It is. Write an empty array to it
    echo '[]' > "base.json"
    fi
else
    printf "%s Check base.json : File base.json does not exist locally. \n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
fi

#
# Archive Tarball
#

# Do not take archive tarball in rolling namespace
if ! [ "${NAMESPACE}" = mainnet-shots-2 ]; then
    printf "%s ********************* Archive Tarball *********************\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    ARCHIVE_TARBALL_FILENAME=tezos-"${NETWORK}"-archive-tarball-"${BLOCK_HEIGHT}".lz4
    printf "%s Archive tarball filename is ${ARCHIVE_TARBALL_FILENAME}\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"

    # LZ4 /var/tezos/node selectively and upload to S3
    printf "%s Archive Tarball : Tarballing /var/tezos/node, LZ4ing, and uploading to S3...\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    tar cvf - . \
    --exclude='node/data/identity.json' \
    --exclude='node/data/lock' \
    --exclude='node/data/peers.json' \
    --exclude='./lost+found' \
    -C /var/tezos \
    | lz4 | tee >(sha256sum | awk '{print $1}' > archive-tarball.sha256) \
    | aws s3 cp - s3://"${S3_BUCKET}"/"${ARCHIVE_TARBALL_FILENAME}" --expected-size 322122547200

    SHA256=$(cat archive-tarball.sha256)

    FILESIZE=$(aws s3api head-object \
        --bucket "${S3_BUCKET}" \
        --key "${ARCHIVE_TARBALL_FILENAME}" \
        --query ContentLength \
        --output text \
        | awk '{ suffix="KMGT"; for(i=0; $1>1024 && i < length(suffix); i++) $1/=1024; print int($1) substr(suffix, i, 1), $3; }')

    # Add file to base.json
    # have to do it here because base.json is being overwritten
    # by other snapshot actions that are faster
    tmp=$(mktemp)
    cp base.json "${tmp}"

    if ! jq \
    --arg BLOCK_HASH "$BLOCK_HASH" \
    --arg BLOCK_HEIGHT "$BLOCK_HEIGHT" \
    --arg BLOCK_TIMESTAMP "$BLOCK_TIMESTAMP" \
    --arg ARCHIVE_TARBALL_FILENAME "${ARCHIVE_TARBALL_FILENAME}" \
    --arg SHA256 "${SHA256}" \
    --arg FILESIZE "${FILESIZE}" \
    --arg TEZOS_VERSION "$TEZOS_VERSION" \
    '. |= 
    [
        {
                ($ARCHIVE_TARBALL_FILENAME): {
                "contents": {
                    "BLOCK_HASH": $BLOCK_HASH,
                    "BLOCK_HEIGHT": $BLOCK_HEIGHT,
                    "BLOCK_TIMESTAMP": $BLOCK_TIMESTAMP,
                    "SHA256": $SHA256,
                    "FILESIZE": $FILESIZE,
                    "TEZOS_VERSION": $TEZOS_VERSION
                }
            }
        }
    ] 
    + .' "${tmp}" > base.json && rm "${tmp}";then
        printf "%s Archive Tarball base.json: Error updating base.json.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    else
        printf "%s Archive Tarball : Sucessfully updated base.json with artifact information.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    fi

    #Upload base.json
    if ! aws s3 cp base.json s3://"${S3_BUCKET}"/base.json; then
        printf "%s Upload base.json : Error uploading file base.json to S3.  \n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    else
        printf "%s Upload base.json : File base.json sucessfully uploaded to S3.  \n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    fi

    # Check if archive-tarball exists in S3 and process redirect
    if ! aws s3api head-object --bucket "${S3_BUCKET}" --key "${ARCHIVE_TARBALL_FILENAME}" > /dev/null; then
        printf "%s Archive Tarball : Error uploading ${ARCHIVE_TARBALL_FILENAME} to S3 Bucket ${S3_BUCKET}.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    else
        printf "%s Archive Tarball : Upload of ${ARCHIVE_TARBALL_FILENAME} to S3 Bucket ${S3_BUCKET} successful!\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"

        # Create archive tarball metadata json
        jq -n \
        --arg BLOCK_HASH "$BLOCK_HASH" \
        --arg BLOCK_HEIGHT "$BLOCK_HEIGHT" \
        --arg BLOCK_TIMESTAMP "$BLOCK_TIMESTAMP" \
        --arg ARCHIVE_TARBALL_FILENAME "$ARCHIVE_TARBALL_FILENAME" \
        --arg SHA256 "$SHA256" \
        --arg FILESIZE "$FILESIZE" \
        --arg TEZOS_VERSION "$TEZOS_VERSION" \
        '{
            "BLOCK_HASH": $BLOCK_HASH, 
            "BLOCK_HEIGHT": $BLOCK_HEIGHT, 
            "BLOCK_TIMESTAMP": $BLOCK_TIMESTAMP,
            "ARCHIVE_TARBALL_FILENAME": $ARCHIVE_TARBALL_FILENAME,
            "FILESIZE": $FILESIZE,
            "SHA256": $SHA256,
            "FILESIZE": $FILESIZE, 
            "TEZOS_VERSION": $TEZOS_VERSION
        }' \
        > "${ARCHIVE_TARBALL_FILENAME}".json

        # Check metadata json exists
        if [ -f "${ARCHIVE_TARBALL_FILENAME}".json ]; then
            printf "%s Archive Tarball : ${ARCHIVE_TARBALL_FILENAME}.json created.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        else
            printf "%s Archive Tarball : Error creating ${ARCHIVE_TARBALL_FILENAME}.json.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        fi

        # Upload archive tarball metadata json
        if ! aws s3 cp "${ARCHIVE_TARBALL_FILENAME}".json s3://"${S3_BUCKET}"/"${ARCHIVE_TARBALL_FILENAME}".json; then
            printf "%s Archive Tarball : Error uploading ${ARCHIVE_TARBALL_FILENAME}.json to S3.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        else
            printf "%s Archive Tarball : Artifact JSON ${ARCHIVE_TARBALL_FILENAME}.json uploaded to S3.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        fi

        # Create archive tarball redirect file
        if ! touch archive-tarball; then
            printf "%s Archive Tarball : Error creating ${NETWORK}-archive-tarball file locally.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        else
            printf "%s Archive Tarball : ${NETWORK}-archive-tarball created sucessfully.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        fi

        # Upload redirect file and set header for previously uploaded LZ4 File
        if ! aws s3 cp archive-tarball s3://"${S3_BUCKET}" --website-redirect /"${ARCHIVE_TARBALL_FILENAME}"; then
            printf "%s Archive Tarball : Error uploading ${NETWORK}-archive-tarball. to S3\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        else
            printf "%s Archive Tarball : Upload of ${NETWORK}-archive-tarball sucessful to S3.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        fi

        # Archive Tarball json redirect file
        if ! touch archive-tarball-json; then
            printf "%s Archive Tarball : Error creating ${NETWORK}-archive-tarball-json file locally.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        else
            printf "%s Archive Tarball : Created ${NETWORK}-archive-tarball-json file locally.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        fi

        # Upload archive tarball json redirect file and set header for previously uploaded archive tarball json File
        if ! aws s3 cp archive-tarball-json s3://"${S3_BUCKET}" --website-redirect /"${ARCHIVE_TARBALL_FILENAME}".json; then
            printf "%s archive Tarball : Error uploading ${NETWORK}-archive-tarball-json file to S3.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        else
            printf "%s archive Tarball : Uploaded ${NETWORK}-archive-tarball-json file to S3.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        fi
    fi
else
    printf "%s Archive Tarball : Not creating archive tarball since we're in mainnet-rolling namespace.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
fi

# dont anticpate rolling snapshot or rolling tarball if we're on mainnet namespace
if ! [ "${NAMESPACE}" = mainnet-shots ]; then
    #
    # Rolling snapshot and tarball vars
    #
    ROLLING_SNAPSHOT_FILENAME="${NETWORK}"-"${BLOCK_HEIGHT}".rolling
    ROLLING_SNAPSHOT=/snapshot-cache-volume/"${ROLLING_SNAPSHOT_FILENAME}"
    ROLLING_TARBALL_FILENAME=tezos-"${NETWORK}"-rolling-tarball-"${BLOCK_HEIGHT}".lz4
    IMPORT_IN_PROGRESS=/rolling-tarball-restore/snapshot-import-in-progress

    # Wait for rolling snapshot file
    while  ! [ -f "${ROLLING_SNAPSHOT}" ]; do
        printf "%s Waiting for ${ROLLING_SNAPSHOT} to exist...\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        sleep 60
    done

    # Wait for rolling snapshot to import to temporary filesystem for tarball.
    while  [ -f "${IMPORT_IN_PROGRESS}" ]; do
        printf "%s Waiting for snapshot to import...\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        sleep 60
    done

    # LZ4 /snapshot-cache-volume/var/tezos/node selectively and upload to S3
    printf "%s ********************* Rolling Tarball *********************\\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"

    printf "%s Rolling Tarball : Tarballing /rolling-tarball-restore/var/tezos/node, LZ4ing, and uploading to S3...\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    tar cvf - . \
    --exclude='node/data/identity.json' \
    --exclude='node/data/lock' \
    --exclude='node/data/peers.json' \
    --exclude='./lost+found' \
    -C /rolling-tarball-restore/var/tezos \
    | lz4 | tee >(sha256sum | awk '{print $1}' > rolling-tarball.sha256) \
    | aws s3 cp - s3://"${S3_BUCKET}"/"${ROLLING_TARBALL_FILENAME}" --expected-size 322122547200

    SHA256=$(cat rolling-tarball.sha256)

    FILESIZE=$(aws s3api head-object \
    --bucket "${S3_BUCKET}" \
    --key "${ROLLING_TARBALL_FILENAME}" \
    --query ContentLength \
    --output text \
    | awk '{ suffix="KMGT"; for(i=0; $1>1024 && i < length(suffix); i++) $1/=1024; print int($1) substr(suffix, i, 1), $3; }')

    # Add file to base.json
    tmp=$(mktemp)
    cp base.json "${tmp}"

    if ! jq \
    --arg BLOCK_HASH "$BLOCK_HASH" \
    --arg BLOCK_HEIGHT "$BLOCK_HEIGHT" \
    --arg BLOCK_TIMESTAMP "$BLOCK_TIMESTAMP" \
    --arg ROLLING_TARBALL_FILENAME "${ROLLING_TARBALL_FILENAME}" \
    --arg SHA256 "${SHA256}" \
    --arg FILESIZE "${FILESIZE}" \
    --arg TEZOS_VERSION "$TEZOS_VERSION" \
    '. |= 
    [
        {
                ($ROLLING_TARBALL_FILENAME): {
                "contents": {
                    "BLOCK_HASH": $BLOCK_HASH,
                    "BLOCK_HEIGHT": $BLOCK_HEIGHT,
                    "BLOCK_TIMESTAMP": $BLOCK_TIMESTAMP,
                    "SHA256": $SHA256,
                    "FILESIZE": $FILESIZE,
                    "TEZOS_VERSION": $TEZOS_VERSION \
                }
            }
        }
    ] 
    + .' "${tmp}" > base.json && rm "${tmp}";then
        printf "%s Rolling Tarball base.json: Error updating base.json.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    else
        printf "%s Rolling Tarball : Sucessfully updated base.json with artifact information.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    fi

    #Upload base.json
    if ! aws s3 cp base.json s3://"${S3_BUCKET}"/base.json; then
        printf "%s Upload base.json : Error uploading file base.json to S3.  \n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    else
        printf "%s Upload base.json : File base.json sucessfully uploaded to S3.  \n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    fi

    # Check if rolling-tarball exists and process redirect
    if ! aws s3api head-object --bucket "${S3_BUCKET}" --key "${ROLLING_TARBALL_FILENAME}" > /dev/null; then
        printf "%s Rolling Tarball : Error uploading ${ROLLING_TARBALL_FILENAME} to S3 Bucket ${S3_BUCKET}.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    else
        printf "%s Rolling Tarball : Upload of ${ROLLING_TARBALL_FILENAME} to S3 Bucket ${S3_BUCKET} successful!\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"

        jq -n \
        --arg BLOCK_HASH "$BLOCK_HASH" \
        --arg BLOCK_HEIGHT "$BLOCK_HEIGHT" \
        --arg BLOCK_TIMESTAMP "$BLOCK_TIMESTAMP" \
        --arg ROLLING_TARBALL_FILENAME "$ROLLING_TARBALL_FILENAME" \
        --arg SHA256 "$SHA256" \
        --arg FILESIZE "$FILESIZE" \
        --arg TEZOS_VERSION "$TEZOS_VERSION" \
        '{
            "BLOCK_HASH": $BLOCK_HASH, 
            "BLOCK_HEIGHT": $BLOCK_HEIGHT, 
            "BLOCK_TIMESTAMP": $BLOCK_TIMESTAMP,
            "ROLLING_TARBALL_FILENAME": $ROLLING_TARBALL_FILENAME,
            "FILESIZE": $FILESIZE,
            "SHA256": $SHA256,
            "FILESIZE": $FILESIZE, 
            "TEZOS_VERSION": $TEZOS_VERSION
        }' \
        > "${ROLLING_TARBALL_FILENAME}".json
        
        if [ -f "${ROLLING_TARBALL_FILENAME}".json ]; then
            printf "%s Rolling Tarball : ${ROLLING_TARBALL_FILENAME}.json created.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        else
            printf "%s Rolling Tarball : Error creating ${ROLLING_TARBALL_FILENAME}.json locally.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        fi

        # upload metadata json
        if ! aws s3 cp "${ROLLING_TARBALL_FILENAME}".json s3://"${S3_BUCKET}"/"${ROLLING_TARBALL_FILENAME}".json; then
            printf "%s Rolling Tarball : Error uploading ${ROLLING_TARBALL_FILENAME}.json to S3.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        else
            printf "%s Rolling Tarball : Metadata JSON ${ROLLING_TARBALL_FILENAME}.json uploaded to S3.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        fi
        
        # Tarball redirect file
        if ! touch rolling-tarball; then
            printf "%s Rolling Tarball : Error creating ${NETWORK}-rolling-tarball file locally.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        else
            printf "%s Rolling Tarball : Created ${NETWORK}-rolling-tarball file locally.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        fi

        # Upload redirect file and set header for previously uploaded LZ4 File
        if ! aws s3 cp rolling-tarball s3://"${S3_BUCKET}" --website-redirect /"${ROLLING_TARBALL_FILENAME}"; then
            printf "%s Rolling Tarball : Error uploading ${NETWORK}-rolling-tarball file to S3.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        else
            printf "%s Rolling Tarball : Uploaded ${NETWORK}-rolling-tarball file to S3.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        fi

        # Rolling Tarball json redirect file
        if ! touch rolling-tarball-json; then
            printf "%s Rolling Tarball : Error creating ${NETWORK}-rolling-tarball-json file locally.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        else
            printf "%s Rolling Tarball : Created ${NETWORK}-rolling-tarball-json file locally.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        fi

        # Upload rolling tarball json redirect file and set header for previously uploaded rolling tarball json File
        if ! aws s3 cp rolling-tarball-json s3://"${S3_BUCKET}" --website-redirect /"${ROLLING_TARBALL_FILENAME}".json; then
            printf "%s Rolling Tarball : Error uploading ${NETWORK}-rolling-tarball-json file to S3.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        else
            printf "%s Rolling Tarball : Uploaded ${NETWORK}-rolling-tarball-json file to S3.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        fi
    fi

    #
    # Rolling Snapshot
    #
    printf "%s ********************* Rolling Tezos Snapshot *********************\\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    # If rolling snapshot exists locally
    if test -f "${ROLLING_SNAPSHOT}"; then
        printf "%s ${ROLLING_SNAPSHOT} exists!\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        # Upload rolling snapshot to S3 and error on failure
        if ! aws s3 cp "${ROLLING_SNAPSHOT}" s3://"${S3_BUCKET}"; then
            printf "%s Rolling Tezos : Error uploading ${ROLLING_SNAPSHOT} to S3.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
        else
            printf "%s Rolling Tezos : Sucessfully uploaded ${ROLLING_SNAPSHOT} to S3.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
            printf "%s Rolling Tezos : Uploading redirect...\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"

            FILESIZE=$(du -h  "${ROLLING_SNAPSHOT}" | cut -f1)
            SHA256=$(sha256sum "${ROLLING_SNAPSHOT}" | awk '{print $1}')

            # Add file to base.json
            tmp=$(mktemp)
            cp base.json "${tmp}"

            if ! jq \
            --arg BLOCK_HASH "$BLOCK_HASH" \
            --arg BLOCK_HEIGHT "$BLOCK_HEIGHT" \
            --arg BLOCK_TIMESTAMP "$BLOCK_TIMESTAMP" \
            --arg ROLLING_SNAPSHOT_FILENAME "${ROLLING_SNAPSHOT_FILENAME}" \
            --arg SHA256 "${SHA256}" \
            --arg FILESIZE "${FILESIZE}" \
            --arg TEZOS_VERSION "$TEZOS_VERSION" \
            '. |= 
            [
                {
                        ($ROLLING_SNAPSHOT_FILENAME): {
                        "contents": {
                            "BLOCK_HASH": $BLOCK_HASH,
                            "BLOCK_HEIGHT": $BLOCK_HEIGHT,
                            "BLOCK_TIMESTAMP": $BLOCK_TIMESTAMP,
                            "SHA256": $SHA256,
                            "FILESIZE": $FILESIZE,
                            "TEZOS_VERSION": $TEZOS_VERSION
                        }
                    }
                }
            ] 
            + .' "${tmp}" > base.json && rm "${tmp}";then
                printf "%s Rolling Snapshot base.json: Error updating base.json.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
            else
                printf "%s Rolling Snapshot : Sucessfully updated base.json with artifact information.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
            fi

            #Upload base.json
            if ! aws s3 cp base.json s3://"${S3_BUCKET}"/base.json; then
                printf "%s Upload base.json : Error uploading file base.json to S3.  \n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
            else
                printf "%s Upload base.json : File base.json sucessfully uploaded to S3.  \n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
            fi

            jq -n \
            --arg BLOCK_HASH "$BLOCK_HASH" \
            --arg BLOCK_HEIGHT "$BLOCK_HEIGHT" \
            --arg BLOCK_TIMESTAMP "$BLOCK_TIMESTAMP" \
            --arg ROLLING_SNAPSHOT_FILENAME "$ROLLING_SNAPSHOT_FILENAME" \
            --arg SHA256 "$SHA256" \
            --arg FILESIZE "$FILESIZE" \
            --arg TEZOS_VERSION "$TEZOS_VERSION" \
            '{
                "BLOCK_HASH": $BLOCK_HASH, 
                "BLOCK_HEIGHT": $BLOCK_HEIGHT, 
                "BLOCK_TIMESTAMP": $BLOCK_TIMESTAMP,
                "ROLLING_SNAPSHOT_FILENAME": $ROLLING_SNAPSHOT_FILENAME,
                "FILESIZE": $FILESIZE,
                "SHA256": $SHA256,
                "FILESIZE": $FILESIZE, 
                "TEZOS_VERSION": $TEZOS_VERSION
            }' \
            > "${ROLLING_SNAPSHOT_FILENAME}".json
            
            printf "%s Rolling Tezos : Metadata JSON created.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"

            # upload metadata json
            aws s3 cp "${ROLLING_SNAPSHOT_FILENAME}".json s3://"${S3_BUCKET}"/"${ROLLING_SNAPSHOT_FILENAME}".json
            printf "%s Rolling Tezos : Metadata JSON ${ROLLING_SNAPSHOT_FILENAME}.json uploaded to S3.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"

            # Rolling snapshot redirect object
            touch rolling

            # Upload rolling tezos snapshot redirect object
            if ! aws s3 cp rolling s3://"${S3_BUCKET}" --website-redirect /"${ROLLING_SNAPSHOT_FILENAME}"; then
                printf "%s Rolling Tezos : Error uploading redirect object for ${ROLLING_SNAPSHOT} to S3.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
            else
                printf "%s Rolling Tezos : Sucessfully uploaded redirect object for ${ROLLING_SNAPSHOT} to S3.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
            fi

            # Rolling snapshot json redirect file
            if ! touch rolling-snapshot-json; then
                printf "%s Rolling Snapshot : Error creating ${NETWORK}-rolling-snapshot-json file locally.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
            else
                printf "%s Rolling snapshot : Created ${NETWORK}-rolling-snapshot-json file locally.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
            fi

            # Upload rolling snapshot json redirect file and set header for previously uploaded rolling snapshot json File
            if ! aws s3 cp rolling-snapshot-json s3://"${S3_BUCKET}" --website-redirect /"${ROLLING_SNAPSHOT_FILENAME}".json; then
                printf "%s Rolling snapshot : Error uploading ${NETWORK}-rolling-snapshot-json file to S3.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
            else
                printf "%s Rolling snapshot : Uploaded ${NETWORK}-rolling-snapshot-json file to S3.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
            fi
        fi
    else
        printf "%s Rolling Tezos : ${ROLLING_SNAPSHOT} does not exist.  Not uploading.  \n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
    fi
else
  printf "%s Skipping rolling snapshot import and export because its too slow on mainnet.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
fi

cd /srv/jekyll || exit

# Get latest values from JSONS

#
# archive tarball
#

# archive tarball filename
ARCHIVE_TARBALL_FILENAME=$(curl -L http://"${S3_BUCKET}".s3-website.us-east-2.amazonaws.com/archive-tarball-json 2>/dev/null | jq -r '.ARCHIVE_TARBALL_FILENAME')
# archive tarball block hash
ARCHIVE_TARBALL_BLOCK_HASH=$(curl -L http://"${S3_BUCKET}".s3-website.us-east-2.amazonaws.com/archive-tarball-json 2>/dev/null | jq -r '.BLOCK_HASH')
# archive tarball block level
ARCHIVE_TARBALL_BLOCK_HEIGHT=$(curl -L http://"${S3_BUCKET}".s3-website.us-east-2.amazonaws.com/archive-tarball-json 2>/dev/null | jq -r '.BLOCK_HEIGHT')
# archive tarball block timestamp
ARCHIVE_TARBALL_BLOCK_TIMESTAMP=$(curl -L http://"${S3_BUCKET}".s3-website.us-east-2.amazonaws.com/archive-tarball-json 2>/dev/null | jq -r '.BLOCK_TIMESTAMP')
# archive tarball filesize
ARCHIVE_TARBALL_FILESIZE=$(curl -L http://"${S3_BUCKET}".s3-website.us-east-2.amazonaws.com/archive-tarball-json 2>/dev/null | jq -r '.FILESIZE')
# archive tarball sha256 sum
ARCHIVE_TARBALL_SHA256SUM=$(curl -L http://"${S3_BUCKET}".s3-website.us-east-2.amazonaws.com/archive-tarball-json 2>/dev/null | jq -r '.SHA256')
# archive tarball tezos version
ARCHIVE_TARBALL_TEZOS_VERSION=$(curl -L http://"${S3_BUCKET}".s3-website.us-east-2.amazonaws.com/archive-tarball-json 2>/dev/null | jq -r '.TEZOS_VERSION')

#
# rolling tarball
#

# rolling tarball filename
ROLLING_TARBALL_FILENAME=$(curl -L http://"${S3_BUCKET}".s3-website.us-east-2.amazonaws.com/rolling-tarball-json 2>/dev/null | jq -r '.ROLLING_TARBALL_FILENAME')
# rolling tarball block hash
ROLLING_TARBALL_BLOCK_HASH=$(curl -L http://"${S3_BUCKET}".s3-website.us-east-2.amazonaws.com/rolling-tarball-json 2>/dev/null | jq -r '.BLOCK_HASH')
# rolling tarball block level
ROLLING_TARBALL_BLOCK_HEIGHT=$(curl -L http://"${S3_BUCKET}".s3-website.us-east-2.amazonaws.com/rolling-tarball-json 2>/dev/null | jq -r '.BLOCK_HEIGHT')
# rolling tarball block timestamp
ROLLING_TARBALL_BLOCK_TIMESTAMP=$(curl -L http://"${S3_BUCKET}".s3-website.us-east-2.amazonaws.com/rolling-tarball-json 2>/dev/null | jq -r '.BLOCK_TIMESTAMP')
# rolling tarball filesize
ROLLING_TARBALL_FILESIZE=$(curl -L http://"${S3_BUCKET}".s3-website.us-east-2.amazonaws.com/rolling-tarball-json 2>/dev/null | jq -r '.FILESIZE')
# rolling tarball sha256 sum
ROLLING_TARBALL_SHA256SUM=$(curl -L http://"${S3_BUCKET}".s3-website.us-east-2.amazonaws.com/rolling-tarball-json 2>/dev/null | jq -r '.SHA256')
# rolling tarball tezos version
ROLLING_TARBALL_TEZOS_VERSION=$(curl -L http://"${S3_BUCKET}".s3-website.us-east-2.amazonaws.com/rolling-tarball-json 2>/dev/null | jq -r '.TEZOS_VERSION')

#
# rolling snapshot
#

# rolling snapshot filename
ROLLING_SNAPSHOT_FILENAME=$(curl -L http://"${S3_BUCKET}".s3-website.us-east-2.amazonaws.com/rolling-snapshot-json 2>/dev/null | jq -r '.ROLLING_SNAPSHOT_FILENAME')
# rolling snapshot block hash
ROLLING_SNAPSHOT_BLOCK_HASH=$(curl -L http://"${S3_BUCKET}".s3-website.us-east-2.amazonaws.com/rolling-snapshot-json 2>/dev/null | jq -r '.BLOCK_HASH')
# rolling snapshot block level
ROLLING_SNAPSHOT_BLOCK_HEIGHT=$(curl -L http://"${S3_BUCKET}".s3-website.us-east-2.amazonaws.com/rolling-snapshot-json 2>/dev/null | jq -r '.BLOCK_HEIGHT')
# rolling snapshot block timestamp
ROLLING_SNAPSHOT_BLOCK_TIMESTAMP=$(curl -L http://"${S3_BUCKET}".s3-website.us-east-2.amazonaws.com/rolling-snapshot-json 2>/dev/null | jq -r '.BLOCK_TIMESTAMP')
# rolling snapshot filesize
ROLLING_SNAPSHOT_FILESIZE=$(curl -L http://"${S3_BUCKET}".s3-website.us-east-2.amazonaws.com/rolling-snapshot-json 2>/dev/null | jq -r '.FILESIZE')
# rolling snapshot sha256 sum
ROLLING_SNAPSHOT_SHA256SUM=$(curl -L http://"${S3_BUCKET}".s3-website.us-east-2.amazonaws.com/rolling-snapshot-json 2>/dev/null | jq -r '.SHA256')
# rolling snapshot tezos version
ROLLING_SNAPSHOT_TEZOS_VERSION=$(curl -L http://"${S3_BUCKET}".s3-website.us-east-2.amazonaws.com/rolling-snapshot-json 2>/dev/null | jq -r '.TEZOS_VERSION')

CLOUDFRONT_URL="https://${NETWORK}.xtz-shots.io/"

cp /snapshot-website-base/* .

NETWORK_SUBSTRING="${NETWORK%%net*}"
if [ "${NETWORK_SUBSTRING}" = main ]; then
    TZSTATS_SUBDOMAIN=""
    TZKT_SUBDOMAIN=""
elif [ "${NETWORK_SUBSTRING}" = hangzhou ]; then
    TZSTATS_SUBDOMAIN="${NETWORK}."
    TZKT_SUBDOMAIN="hangzhou2net."
else
    TZSTATS_SUBDOMAIN="${NETWORK_SUBSTRING}."
    TZKT_SUBDOMAIN="${NETWORK}."
fi

# Create index.html
cat << EOF > index.md
---
# Page settings
layout: snapshot
keywords:
comments: false
# Hero section
title: Tezos snapshots for ${NETWORK}
description: 
# Author box
author:
title: Brought to you by Oxhead Alpha
title_url: 'https://medium.com/the-aleph'
external_url: true
description: A Tezos core development company, providing common goods for the Tezos ecosystem. <a href="https://medium.com/the-aleph" target="_blank">Learn more</a>.
# Micro navigation
micro_nav: true
# Page navigation
page_nav:
home:
    content: Previous page
    url: 'https://xtz-shots.io/index.html'
---
# Tezos snapshots for ${NETWORK}

Tezos version used for snapshotting: \`${TEZOS_VERSION}\`
## Archive tarball
[Download Archive Tarball](${CLOUDFRONT_URL}archive-tarball)

Block height: $ARCHIVE_TARBALL_BLOCK_HEIGHT

Block hash: \`${ARCHIVE_TARBALL_BLOCK_HASH}\`

[Verify on TzStats](https://${TZSTATS_SUBDOMAIN}tzstats.com/${ARCHIVE_TARBALL_BLOCK_HASH}){:target="_blank"} - [Verify on TzKT](https://${TZKT_SUBDOMAIN}tzkt.io/${ARCHIVE_TARBALL_BLOCK_HASH}){:target="_blank"}

Block timestamp: $ARCHIVE_TARBALL_BLOCK_TIMESTAMP

Size: ${ARCHIVE_TARBALL_FILESIZE}

Checksum (SHA256): 
\`\`\`
${ARCHIVE_TARBALL_SHA256SUM}
\`\`\`

[Artifact Metadata](${CLOUDFRONT_URL}archive-tarball-json)
## Rolling tarball
[Download Rolling Tarball](${CLOUDFRONT_URL}rolling-tarball)

Block height: $ROLLING_TARBALL_BLOCK_HEIGHT

Block hash: \`${ROLLING_TARBALL_BLOCK_HASH}\`

[Verify on TzStats](https://${TZSTATS_SUBDOMAIN}tzstats.com/${ROLLING_TARBALL_BLOCK_HASH}){:target="_blank"} - [Verify on TzKT](https://${TZKT_SUBDOMAIN}tzkt.io/${ROLLING_TARBALL_BLOCK_HASH}){:target="_blank"}

Block timestamp: $ROLLING_TARBALL_BLOCK_TIMESTAMP

Size: ${ROLLING_TARBALL_FILESIZE}

Checksum (SHA256): 
\`\`\`
${ROLLING_TARBALL_SHA256SUM}
\`\`\`

[Artifact Metadata](${CLOUDFRONT_URL}rolling-tarball-json)
## Rolling snapshot
[Download Rolling Snapshot](${CLOUDFRONT_URL}rolling)

Block height: $ROLLING_SNAPSHOT_BLOCK_HEIGHT

Block hash: \`${ROLLING_SNAPSHOT_BLOCK_HASH}\`

[Verify on TzStats](https://${TZSTATS_SUBDOMAIN}tzstats.com/${ROLLING_SNAPSHOT_BLOCK_HASH}){:target="_blank"} - [Verify on TzKT](https://${TZKT_SUBDOMAIN}tzkt.io/${ROLLING_SNAPSHOT_BLOCK_HASH}){:target="_blank"}

Block timestamp: $ROLLING_SNAPSHOT_BLOCK_TIMESTAMP

Size: ${ROLLING_SNAPSHOT_FILESIZE}

Checksum (SHA256): 
\`\`\`
${ROLLING_SNAPSHOT_SHA256SUM}
\`\`\`

[Artifact Metadata](${CLOUDFRONT_URL}rolling-snapshot-json)
## How to use
### Archive Tarball
Issue the following commands:
\`\`\`bash
curl -LfsS "${CLOUDFRONT_URL}${ARCHIVE_TARBALL_FILENAME}" \
| lz4 -d | tar -x -C "/var/tezos"
\`\`\`
Or simply use the permalink:
\`\`\`bash
curl -LfsS "${CLOUDFRONT_URL}archive-tarball" \
| lz4 -d | tar -x -C "/var/tezos"
\`\`\`
### Rolling Tarball
Issue the following commands:
\`\`\`bash
curl -LfsS "${CLOUDFRONT_URL}${ROLLING_TARBALL_FILENAME}" \
| lz4 -d | tar -x -C "/var/tezos"
\`\`\`
Or simply use the permalink:
\`\`\`bash
curl -LfsS "${CLOUDFRONT_URL}rolling-tarball" \
| lz4 -d | tar -x -C "/var/tezos"
\`\`\`
### Rolling Snapshot
Issue the following commands:
\`\`\`bash
wget ${CLOUDFRONT_URL}${ROLLING_SNAPSHOT_FILENAME}
tezos-node snapshot import ${ROLLING_SNAPSHOT_FILENAME} --block ${BLOCK_HASH}
\`\`\`
Or simply use the permalink:
\`\`\`bash
wget ${CLOUDFRONT_URL}rolling -O tezos-${NETWORK}.rolling
tezos-node snapshot import tezos-${NETWORK}.rolling
\`\`\`
### More details
[About xtz-shots.io](https://xtz-shots.io/getting-started/).

[Tezos documentation](https://tezos.gitlab.io/user/snapshots.html){:target="_blank"}.
EOF

echo "**** DEBUG OUTPUT OF index.md *****"
cat index.md
echo "**** end debug ****"

chmod -R 777 index.md
chown jekyll:jekyll -R /usr/gem

# convert to index.html with jekyll
bundle install
bundle exec jekyll build

# upload index.html to website
if ! aws s3 cp _site/ s3://"${NETWORK}".xtz-shots.io --recursive --include "*"; then
    printf "%s Website Build & Deploy : Error uploading site to S3.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
else
    printf "%s Website Build & Deploy  : Sucessfully uploaded website to S3.\n" "$(date "+%Y-%m-%d %H:%M:%S" "$@")"
fi