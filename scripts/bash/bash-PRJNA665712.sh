#!/usr/bin/env bash
# =============================================================================
# bash-PRJNA665712.sh
#
# BioProject PRJNA665712
#
# CURRENT MODE: ACCESSION LIST DOWNLOAD + SRA DOWNLOAD + FASTQ EXTRACTION
#
# Script location: /home/notes/Documents/users/bioinformatica/scripts/bash/
#
# This script:
#   1) Downloads the SRR accession list for the BioProject from ENA
#      (skips the download if the list is already present on disk)
#   2) Downloads .sra files from NCBI using prefetch (skips accessions
#      whose .sra file is already present on disk)
#   3) Extracts the FASTQ files from the .sra files using fasterq-dump
#
# The following step is COMMENTED OUT and is NOT executed:
#   4) FASTQ -> FASTA conversion using awk
#
# Existing accession list, SRA, and FASTA files are NOT deleted or
# discarded.
#
# NOTE ON DIRECTORY LAYOUT:
#   Scripts, raw-data, and results all live under a single root:
#     /home/notes/Documents/users/bioinformatica/
#   SRA Toolkit (prefetch, fasterq-dump) is expected to be available
#   on PATH (e.g. installed via the system package manager), rather
#   than pointed to by an explicit binary path.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 1. PATHS
# -----------------------------------------------------------------------------

BIOINFO_ROOT="/home/notes/Documents/users/bioinformatica"
PROJECT_ACCESSION="PRJNA665712"

RAW_DIR="$BIOINFO_ROOT/raw-data/$PROJECT_ACCESSION"
RESULTS_DIR="$BIOINFO_ROOT/results/$PROJECT_ACCESSION"  # not used by this script yet;
                                                          # used later by the DADA2
                                                          # pipeline (scripts/dada2/)

SRR_DIR="$RAW_DIR/srr"
SRA_DIR="$RAW_DIR/sra"
FASTQ_DIR="$RAW_DIR/fastq"
FASTA_DIR="$RAW_DIR/fasta"   # reserved; FASTQ -> FASTA conversion step is disabled below

ACC_LIST="$SRR_DIR/SRR-PRJNA665712.txt"

THREADS=4

# -----------------------------------------------------------------------------
# 2. ACCESSION LIST DOWNLOAD
# -----------------------------------------------------------------------------
echo "== Accession list =="

mkdir -p "$SRR_DIR"

if [[ -s "$ACC_LIST" ]]; then
  echo "  [skip]     accession list already present: $ACC_LIST"
else
  command -v curl >/dev/null 2>&1 || {
    echo "ERROR: curl not found; it is required to download the accession list."
    exit 1
  }

  echo "  [download] fetching run accessions for $PROJECT_ACCESSION from ENA"

  curl -fsSL \
    "https://www.ebi.ac.uk/ena/portal/api/filereport?accession=${PROJECT_ACCESSION}&result=read_run&fields=run_accession&format=tsv" \
    | tail -n +2 > "$ACC_LIST"

  # tail -n +2:
  #   drops the "run_accession" header row returned by the API, leaving
  #   one SRR accession per line, matching the format the rest of this
  #   script expects.
  #
  # NOTE: ENA and NCBI SRA share the same run accessions, so the SRR
  # IDs returned here work directly with prefetch/fasterq-dump below.
  # If you prefer to query NCBI directly instead, this step can be
  # swapped for Entrez Direct's esearch/efetch.
fi
echo "========================"
echo

# -----------------------------------------------------------------------------
# 3. PRE-FLIGHT CHECKS
# -----------------------------------------------------------------------------
echo "== Pre-flight checks =="

[[ -s "$ACC_LIST" ]] || {
  echo "ERROR: accession list is empty or could not be generated: $ACC_LIST"
  exit 1
}

command -v prefetch >/dev/null 2>&1 || {
  echo "ERROR: 'prefetch' not found in PATH. Install SRA Toolkit or add it to PATH."
  exit 1
}

command -v fasterq-dump >/dev/null 2>&1 || {
  echo "ERROR: 'fasterq-dump' not found in PATH. Install SRA Toolkit or add it to PATH."
  exit 1
}

# sra/ and fastq/ may not exist yet -- create them if missing.
# fasta/ is also created here to keep the raw-data layout complete,
# even though the FASTQ -> FASTA step (Step C) is disabled below.
mkdir -p "$SRA_DIR" "$FASTQ_DIR" "$FASTA_DIR"

N_ACC=$(grep -c . "$ACC_LIST")

echo "Accession list OK: $N_ACC accessions found in $ACC_LIST"
echo "RAW_DIR:           $RAW_DIR"
echo "FASTQ output:      $FASTQ_DIR"
echo "========================"
echo

# -----------------------------------------------------------------------------
# 4. MAIN LOOP — one accession at a time
# -----------------------------------------------------------------------------
i=0

while IFS= read -r acc || [[ -n "$acc" ]]; do

  acc="${acc%$'\r'}"
  [[ -z "$acc" ]] && continue

  i=$((i + 1))

  echo "[$i/$N_ACC] $acc"

  # ===========================================================================
  # STEP A: SRA DOWNLOAD
  # ===========================================================================
  #
  # ACTIVE STEP
  #
  # Existing .sra files are NOT deleted or re-downloaded.
  #
  SRA_FILE="$SRA_DIR/$acc/$acc.sra"

  if [[ -f "$SRA_FILE" ]]; then
    echo "  [skip]     .sra already present: $SRA_FILE"
  else
    echo "  [download] prefetch $acc"

    prefetch \
      --output-directory "$SRA_DIR" \
      "$acc"

    # --output-directory:
    #   prefetch writes to $SRA_DIR/$acc/$acc.sra, matching the path
    #   expected by Step B below.
  fi

  # ===========================================================================
  # STEP B: SRA -> FASTQ
  # ===========================================================================
  #
  # ACTIVE STEP
  #
  if [[ ! -f "$SRA_FILE" ]]; then
    echo "  [ERROR]    .sra file not found:"
    echo "             $SRA_FILE"
    echo "             FASTQ extraction cannot continue for $acc"
    continue
  fi

  if compgen -G "${FASTQ_DIR}/${acc}*.fastq" > /dev/null; then
    echo "  [skip]     .fastq already present for $acc"
  else
    echo "  [extract]  fasterq-dump $acc"

    fasterq-dump \
      --split-files \
      --skip-technical \
      --threads "$THREADS" \
      --outdir "$FASTQ_DIR" \
      "$SRA_FILE"

    # --split-files:
    #   Paired-end reads are written as:
    #     ${acc}_1.fastq
    #     ${acc}_2.fastq
    #
    # --skip-technical:
    #   Excludes technical reads and keeps the biological reads.
    #
    # --threads:
    #   Number of threads used for extraction.
    #
    # --outdir:
    #   Directory where FASTQ files are written.
  fi

  # ===========================================================================
  # STEP C: FASTQ -> FASTA
  # ===========================================================================
  #
  # DISABLED.
  #
  # Existing FASTA files are NOT deleted.
  #
  # for fq in "$FASTQ_DIR/${acc}"*.fastq; do
  #   [[ -e "$fq" ]] || continue
  #
  #   base=$(basename "$fq" .fastq)
  #   fa="$FASTA_DIR/${base}.fasta"
  #
  #   if [[ -f "$fa" ]]; then
  #     echo "  [skip]     .fasta already present: $fa"
  #     continue
  #   fi
  #
  #   echo "  [convert]  ${base}.fastq -> ${base}.fasta"
  #
  #   awk 'NR % 4 == 1 { sub(/^@/, ">"); print }
  #        NR % 4 == 2 { print }' "$fq" > "$fa"
  # done

done < "$ACC_LIST"

echo
echo "== Done: $i accessions processed =="
echo "FASTQ: $FASTQ_DIR"
echo
echo "Accession list download: ACTIVE"
echo "SRA download:             ACTIVE"
echo "FASTQ extraction:         ACTIVE"
echo "FASTA conversion:         DISABLED"
