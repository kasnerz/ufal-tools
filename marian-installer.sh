#!/bin/bash
# Installation of Marian NMT and prerequisites for UFAL cluster environment.
# Derived from eman seed for marian (http://ufal.mff.cuni.cz/eman)
# Ondrej Bojar and Josef Jon
# vim: tabstop=2 expandtab


marianrepo=https://github.com/marian-nmt/marian-dev.git

function die() { echo "$@" >&2; exit 1; }
function warn() { echo "$@" >&2; }
set -o pipefail


# These environment variables are recognized by the script:
#   defvar BRANCH default='' help='which marian branch to use' \
#   defvar BOOST help='which boost to use' \
#     default='/net/me/merkur3/varis/boost/boost_1_56_0-py3.5-g++5.4' \
#   defvar CMAKE help='which cmake to use' \
#     default='' \
#   defvar GCC help='which gcc to use' \
#     default='/ha/opt/x86_64/tools/gcc/gcc-5.4.0' \
#   defvar EMAN_QUEUE default='gpu.q' help="which queue to submit to" \
#   defvar EMAN_GPUS default='1' help="need a machine with CUDA by default" \
#   defvar EMAN_GPUMEM default='6g' help="one of UFAL's better machines" \
#   defvar USE_CUDA default='yes' \
#     help='compile Marian with CUDA support; the particular value of this variable is probably ignored but you can set it to empty to compile only non-GPU parts of Marian, i.e. marian-decoder with only CPU support' \
#   defvar CUDA_HOME="/opt/cuda/10.1/"
#TODO - everything aboce this?
# another TODO - if we want AVX512VNNI (some new intel stuff for 8bit matrix operations, it is useful for small quantized student models), we need gcc > 8? maybe


# Where to install/compile to:
# If the script is run without parameters, it assumes that it was already run
# before and that now we run it in the directory where it already is.


MYDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )" # get script directory
DESIREDDIR=$1
if [ -z "$DESIREDDIR" ]; then
  # no argument given
  if [ -e "guessmarian" ]; then
    # we were run in a directory where marian was already compiled
    # we just need to compile for this architecture
    TARGETDIR=$(pwd)
  else
    die "usage: $0 target-dir-to-create"
  fi
else
  if [ -e "$DESIREDDIR" ]; then
    warn "$DESIREDDIR already exists, not touching it."
    warn "If you want to add another compilation, do this:"
    warn "  cd $DESIREDDIR && ./compile-again-for-this-architecture.sh"
    exit 1
  fi
  mkdir -p "$DESIREDDIR" || die "Failed to create $DESIREDDIR"
  TARGETDIR=$(readlink -f "$DESIREDDIR")
  cp "${BASH_SOURCE[0]}" "$TARGETDIR/compile-again-for-this-architecture.sh" \
  || die "Failed to copy self to $TARGETDIR/compile-again-for-this-architecture.sh"
fi
warn "### Compiling marian for the CPU+GPU architecture of "$(hostname)" into $TARGETDIR"
cd "$TARGETDIR" || die "Failed to chdir to $TARGETDIR"

### Default settings (good for ufal)
GCC=/usr/
# where do all cuda versions live?
CUDA_HOMES=/opt/cuda


### Environment-specific steps and settings
hostname=$(hostname)
if [[ "$hostname" =~ metacentrum.cz ]] || [[ "$hostname" =~ grid.cesnet.cz ]] || [[ "$hostname" =~ cerit-sc.cz ]]
then
  # adan and doom
  module add cuda-10.1
  module add gcc-5.3.0
  GCC=/software/gcc/5.3.0
  CUDA_HOMES=/software/cuda
  #module add cmake-3.6.1
fi


# use my MKL on AIC
if [[ "$hostname" == cpu-node* ]]; then
  MKL_ROOT=/lnet/aic/personal/jon/mkl/2021.2.0
#  [ -d "$MKL_ROOT" ] || die "MKL missing: $MKL_ROOT" -- not strictly needed
  MKL_STRING=" -DMKL_INCLUDE_DIR=$MKL_ROOT/include/ -DMKL_ROOT=$MKL_ROOT"
fi

# use MKL on metacentrum
if [ -d /mnt/storage-brno8/home/cepin/mkl/2021.2.0/ ];then
  MKL_ROOT=/mnt/storage-brno8/home/cepin/mkl/2021.2.0/ 
  MKL_STRING=" -DMKL_INCLUDE_DIR=$MKL_ROOT/include/ -DMKL_ROOT=$MKL_ROOT"
fi

### Less environment specific steps

# in ideal case, nvidia-smi exists and we want to use this version of CUDA
CUDA_VERSION=$(nvidia-smi | grep -oP "CUDA Version: \K...." )
USE_CUDA=yes
if [ -e $CUDA_HOMES/$CUDA_VERSION/bin/nvcc ]
then
  CUDA_HOME="$CUDA_HOMES/$CUDA_VERSION/"
elif [ -e $CUDA_HOMES/10.1 ]; then
  # Strange situation when nvidia-smi returns e.g. version 11.2
  CUDA_HOME="$CUDA_HOMES/10.1/"
  CUDA_VERSION=$("$CUDA_HOME/bin/nvcc" --version | grep -oP "release \K....")
  warn "Compiling with CUDA version $CUDA_VERSION from $CUDA_HOME"
else 
  if [ -z "$CUDA_VERSION" ];then
    USE_CUDA=no
    warn "Warning: CUDA not located, installing without GPU support!"
  else
    warn "CUDA seems to be installed, but install dir not found, hopefully CMake will find it"
  fi
fi


## Construct chipset fingerprint
instr=""
for kw in sse2 ssse3 avx avx2 avx512 avx512vnni; do
  if grep -q " $kw " /proc/cpuinfo; then
    instr="$instr-$kw"
  fi
done
instr=${instr:1:100}
  # strip the leading -

if [ ! x$USE_CUDA == xyes ]; then
  warn "Compiling Marian **without** GPU support."
  cuda_flag="-DCOMPILE_CUDA=off"
  fingerprint="CPUONLY-CPU-$instr"
else
  warn "Compiling Marian with this CUDA_HOME: $CUDA_HOME"
  cuda_flag="-DCUDA_TOOLKIT_ROOT_DIR=$CUDA_HOME"
  fingerprint="CUDA-$CUDA_VERSION-CPU-$instr"
fi
warn "Compiling this version: $fingerprint"

# check if the desired branch exists (test works also with BRANCH == "")
if ! git ls-remote --heads "$marianrepo" | grep "refs/heads/$BRANCH" -q; then \
  echo "The branch '$BRANCH' does not exist at $marianrepo, assuming it is a commit"
fi

set -ex # exit after any failure and show all commands run

# get cmake
if [ -z "$CMAKE" ]; then
  if [ ! -e cmake-3.19.6 ]; then
    wget https://cmake.org/files/v3.19/cmake-3.19.6.tar.gz
    tar xzf cmake-3.19.6.tar.gz
    cd cmake-3.19.6
    ./configure --prefix=.
    make -j16
    make install
    cd $TARGETDIR
  else
    warn "Will use the existing ./cmake-3.19.6"
  fi
  usecmake=$TARGETDIR/cmake-3.19.6
else
  usecmake=$CMAKE
fi
warn "Using cmake: $usecmake"

# get marian
if [ ! -e marian ]; then
  git clone "$marianrepo" marian
  cd marian
  [ -z "$BRANCH" ] || git checkout "$BRANCH"
  cd $TARGETDIR
else
  warn "Will use the existing ./marian/"
fi


if [ ! -e marian/build-$fingerprint ]; then
  warn "RUNNING BUILD in marian/build-$fingerprint"
  mkdir marian/build-$fingerprint
  cd marian/build-$fingerprint

  # build marian
  $usecmake/bin/cmake \
    $cuda_flag $MKL_STRING \
    -DBOOST_ROOT=$BOOST/ \
    -DBOOST_INCLUDEDIR=$BOOST/include \
    -DBOOST_LIBRARYDIR=$BOOST/lib \
    -DCMAKE_C_COMPILER=$GCC/bin/gcc \
    -DCMAKE_CXX_COMPILER=$GCC/bin/g++ \
    -DCMAKE_MODULE_LINKER_FLAGS="-lutil -ldl  -lcblas -lblas" \
    -DCMAKE_EXE_LINKER_FLAGS="-lutil -ldl -lcblas -lblas " \
    -DCMAKE_SHARED_LINKER_FLAGS="-lutil -ldl -lcblas -lblas " \
    -DCMAKE_C_STANDARD_LIBRARIES="-lpthread" \
    -DCMAKE_REQUIRED_FLAGS="-lpthread" \
	-DUSE_SENTENCEPIECE=on \
	-DBUILD_CPU=on \
	-DUSE_DOXYGEN=off \
    -DBoost_DEBUG=1 ..
	
  # compile marian
  make -j16 VERBOSE=1
  # check if GPU version was compiled
  if [ ! x$USE_CUDA == xyes ]; then
    [ -x ./marian ] \
      || die "Marian was not compiled, probably failed to find CUDA?"
  fi
  # go back to our target dir
  cd $TARGETDIR
fi

# create the automatic guessing which build to use
if [ ! -e ./guessmarian ]; then
  cat << KONEC > ./guessmarian
#!/bin/bash
# run the appropriate compilation of marian(-decoder/-scorer)
# create a symlink to this script called guessmarian-decoder to get the
# decoder, etc.
function die() { echo "\$@" >&2; exit 1; }
hn=\$(hostname)
if [ -e $TARGETDIR/marian/build-\$hn ]; then
# exact build for the machine, probably may be useful for some exceptions
  need=\$hn
else
  # Guessing build based on CUDA version and chipset

  instr=""
  for kw in sse2 ssse3 avx avx2 avx512 avx512vnni; do
    if grep -q " \$kw " /proc/cpuinfo; then
      instr="\$instr-\$kw"
    fi
  done
  instr=\${instr:1:100}
    # strip the leading -

# First, try to parse nvidia-smi

CUDA_VERSION=\$(nvidia-smi | grep -oP "CUDA Version: \K...." )
  if [ -e $TARGETDIR/marian/build-CUDA-\$CUDA_VERSION-CPU-\$instr/marian ]
  then
    need="CUDA-\$CUDA_VERSION-CPU-\$instr"
    export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/opt/cuda/$CUDA_VERSION/lib64:/opt/cuda/$CUDA_VERSION/cudnn/$CUDNN/
  else
    if [ -e "/opt/cuda/11.1/bin/nvcc" ]; then
      CUDNN=8.0
      CUDA_VERSION=11.1
    elif [ -e "/opt/cuda/11.0/bin/nvcc" ]; then
      CUDNN=8.0
      CUDA_VERSION=11.0
    elif [ -e "/opt/cuda/10.2/bin/nvcc" ]; then
      CUDNN=7.6
      CUDA_VERSION=10.2
    elif [ -e "/opt/cuda/10.1/bin/nvcc" ]; then
      CUDNN=7.6
      CUDA_VERSION=10.1
    elif [ -e "/opt/cuda/9.2/bin/nvcc" ]; then
      CUDNN=7.4
      CUDA_VERSION=9.2
    else
      echo "no suitable CUDA found, falling back to CPU-only (can't be used for training)" >&2
      CUDA_VERSION=
    fi
    export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/opt/cuda/$CUDA_VERSION/lib64:/opt/cuda/$CUDA_VERSION/cudnn/$CUDNN/
    need="CUDA-$CUDA_VERSION"
    if [[ ! -z "\$CUDA_VERSION" ]]; then
      need="CUDA-\$CUDA_VERSION-CPU-\$instr"
    else
      need=CPUONLY-CPU-\$instr
    fi
  fi
fi
guessed=\$( ls -d $TARGETDIR/marian/build-* \
            | grep "\$need" \
            | head -n 1 )
[ -d "\$guessed" ] || die "No matching build found: \$guessed (\$need)"
programname=\$(basename \$0 | sed 's/guess//')
MARIAN="\$guessed/\$programname"
echo "Guessed marian: \$MARIAN" >&2
export LD_LIBRARY_PATH=$GCC/lib64/:\$LD_LIBRARY_PATH
echo "========== guessmarian reports details: env" >&2
env >&2
echo "========== guessmarian reports details: ldd" >&2
ldd \$MARIAN >&2
echo "========== guessmarian runs:" >&2
set -x
\$MARIAN "\$@"
exit \$?
KONEC
  chmod 755 guessmarian
fi

[ -e ./guessmarian-decoder ] || ln -s ./guessmarian ./guessmarian-decoder
[ -e ./guessmarian-scorer ] || ln -s ./guessmarian ./guessmarian-scorer
