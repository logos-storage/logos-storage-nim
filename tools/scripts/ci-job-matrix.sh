#!/usr/bin/env bash

# This script outputs a JSON configuration file for continuous integration with
# Github actions. See .github/workflows/ci.yml for an example of how it's used.

# remembers how many jobs were generated
jobs_generated=0

# outputs a github actions job
job () {
  # output a comma separator between jobs
  if (( $jobs_generated >= 1 )); then
    echo -n ","
  fi
  (( jobs_generated++ ))

  # output github actions job as JSON
  echo "{\
    \"os\": \"${job_os}\", \
    \"cpu\": \"${job_cpu}\", \
    \"builder\": \"${job_builder}\", \
    \"tests\": \"${job_tests}\", \
    \"includes\": \"${job_includes}\", \
    \"nim_version\": \"${nim_version}\", \
    \"shell\": \"${job_shell}\", \
    \"job_number\": \"${jobs_generated}\" \
  }"
}

# sets parameters for a linux job
linux () {
  job_os="linux"
  job_cpu="amd64"
  job_builder="ubuntu-latest"
  job_shell="bash --noprofile --norc -e -o pipefail"
}

# sets parameters for a macos job
macos () {
  job_os="macos"
  job_cpu="arm64"
  job_builder="macos-15"
  job_shell="bash --noprofile --norc -e -o pipefail"
}

# sets parameters for a windows job
windows () {
  job_os="windows"
  job_cpu="amd64"
  job_builder="windows-latest"
  job_shell="msys2"
}

# outputs a unit test job
unit_test () {
  job_tests="unittest"
  job_includes=""
  job
}

# finds all files named test*.nim in the specified directory
find_tests () {
  local dir=$1
  find $dir -name 'test*.nim'
}

# creates batches from stdin elements, joined by a separator
batch () {
  local batch_size=$1
  local separator=$2
  xargs -n "$batch_size" | sed 's/ /'"$separator"'/g'
}

# outputs a single integration test job
integration_test_job () {
  job_tests="integration"
  job_includes="$1"
  job
}

# outputs several integration test jobs
integration_test () {
  # each test that lasts up to 30 minutes gets its own ci job
  for tests in $(find_tests tests/integration/30_minutes | batch 1 ","); do
    integration_test_job $tests
  done

  # tests that last up to 5 minutes are batched per 6 into a ci job
  for tests in $(find_tests tests/integration/5_minutes | batch 6 ","); do
    integration_test_job $tests
  done

  # tests that last up to 1 minute are batched per 30 into a ci job
  for tests in $(find_tests tests/integration/1_minute | batch 30 ","); do
    integration_test_job $tests
  done

  # fail when there are integration tests with an unknown duration. nat/ is
  # excluded: those real-topology scenarios run via the nat-integration job.
  local filter='1_minute\|5_minutes\|30_minutes'
  local unknown=$(find_tests tests/integration | grep -v "$filter" | grep -v '/nat/')
  if [ "$unknown" != "" ]; then
    echo "Error: Integration tests need to be in either the 1_minute," >&2
    echo "       5_minutes, or 30_minutes directory, based on the maximum" >&2
    echo "       running time of the test. This is used to group the" >&2
    echo "       integration tests into batches to speed up the the" >&2
    echo "       continuous integration." >&2
    echo "       Offending tests: $unknown" >&2
    exit 1
  fi
}


# outputs a libstorage test job
libstorage_test () {
  job_tests="libstorage"
  job_includes=""
  job
}

# outputs the NAT real-topology integration job (all scenarios).
# Linux-only: needs network-namespace + iptables manipulation.
nat_integration_tests () {
  job_tests="nat-integration"
  job_includes=""
  job
}

# outputs jobs for all test types
all_tests () {
  unit_test
  integration_test
  libstorage_test
  if [ "$job_os" = "linux" ]; then
    nat_integration_tests
  fi
}

# outputs jobs for the specified operating systems and all test types
os_jobs () {
  local operating_systems=$@
  echo "["
  for os in $operating_systems; do
    $os
    all_tests
  done
  echo "]"
}

os_jobs ${@:-linux macos windows}
