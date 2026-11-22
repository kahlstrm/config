# Handles one `amp orb provider` job, after Amp's Docker example
# (https://ampcode.com/docs/orbs/self-hosted): the job arrives in ORB_OPERATION, ORB_ID,
# ORB_IMAGE, ORB_SNAPSHOT_ID, ORB_TOKEN and AMP_URL. Every operation is safe to repeat.
if [[ ! ${ORB_ID-} =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$ ]]; then
  echo "unexpected ORB_ID: ${ORB_ID-}" >&2
  exit 1
fi

exists() { docker container inspect "$ORB_ID" > /dev/null 2>&1; }

case "${ORB_OPERATION-}" in
  spawn)
    if exists; then
      # Bootstrap runs detached, and Amp reports only that the orb never connected. What the last
      # one here said goes to the journal, and from there to the VM's console.
      docker cp "$ORB_ID:$ORB_BOOTSTRAP_LOG" - 2> /dev/null | tar --extract --to-stdout 2> /dev/null |
        tail -n 20 | sed "s/^/$ORB_ID: /" | systemd-cat --identifier "$ORB_LABEL-bootstrap" || true
    else
      image=$ORB_IMAGE
      # A project snapshot saved on this VM starts the orb with its setup already done.
      if [ -n "${ORB_SNAPSHOT_ID-}" ] && docker image inspect "$ORB_SNAPSHOT_ID" > /dev/null 2>&1; then
        image=$ORB_SNAPSHOT_ID
      fi
      # Privileged, so Docker and KVM work in the orb. The browser needs the larger /dev/shm.
      docker create --init --privileged --name "$ORB_ID" --label "$ORB_LABEL" \
        --cpus "$ORB_CPUS" --memory "$ORB_MEMORY" --shm-size 1g "$image" sleep infinity > /dev/null
    fi
    docker start "$ORB_ID" > /dev/null
    # As the image's default user; --env with a bare name copies the value from this job.
    environment=(--env ORB_TOKEN)
    if [ -n "${AMP_URL-}" ]; then
      environment+=(--env AMP_URL)
    fi
    # shellcheck disable=SC2016 # the orb's shell expands the path
    docker exec --detach "${environment[@]}" --env ORB_BOOTSTRAP_LOG "$ORB_ID" \
      sh -c 'exec amp orb bootstrap > "$ORB_BOOTSTRAP_LOG" 2>&1'
    ;;
  pause)
    if exists; then
      # What only this orb holds, for cleanup; within two minutes, so the job ends in time.
      if [ "$(docker container inspect --format '{{.State.Running}}' "$ORB_ID")" = true ]; then
        orb-cleanup record "$ORB_ID" || true
      fi
      docker stop "$ORB_ID" > /dev/null
      if [ -n "${ORB_SNAPSHOT_ID-}" ]; then
        docker commit --change "LABEL $ORB_LABEL-snapshot=1" "$ORB_ID" "$ORB_SNAPSHOT_ID" > /dev/null
      fi
    fi
    ;;
  delete)
    if exists; then
      docker rm --force --volumes "$ORB_ID" > /dev/null
    fi
    ;;
  *)
    echo "unknown ORB_OPERATION: ${ORB_OPERATION-}" >&2
    exit 1
    ;;
esac
