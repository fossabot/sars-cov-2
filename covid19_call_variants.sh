#!/bin/bash

# Example command: `bash covid19_call_variants.sh
# reference/nCoV-2019.reference.fasta
# data/twist-target-capture/RNA_control_spike_in_10_6_100k_reads.fastq.gz
# reference/artic-v1/ARTIC-V1.bed`

set -eou pipefail

# argv
: "${reference:=${1}}"
: "${input_fastq:=${2}}"
: "${primer_bed_file:=${3}}"

# defaults
: "${length_threshold:=600}" # max length to be considered "short read" sequencing
: "${threads:=4}"
: "${prefix:=results}"
: "${min_quality:=20}"

echo "reference=${reference}"
echo "input_fastq=${input_fastq}"
echo "primer_bed_file=${primer_bed_file}"
echo "length_threshold=${length_threshold}"
echo "threads=${threads}"
echo "min_quality=${min_quality}"


# detect if we have long or short reads to adjust minimap2 parameters
mapping_mode=$(
  head -n 400 "${input_fastq}" \
    | awk \
    -v "thresh=${length_threshold}" \
    'NR % 4 == 2 {s+= length}END {if (s/(NR/4) > thresh) {print "map-ont"} else {print "sr"}}'
)

# Minimap2
MINIMAP_OPTS="-K 20M -a -x ${mapping_mode} -t ${threads}"
echo "[1] Running minimap with options: ${MINIMAP_OPTS}"

# Trim polyA tail for alignment (33 bases)
seqtk trimfq -e 33 "${reference}" > "${reference}.trimmed.fa"

# shellcheck disable=SC2086
minimap2 ${MINIMAP_OPTS} \
  "${reference}.trimmed.fa" \
  "${input_fastq}"  \
  | samtools \
    view \
    -u \
    -h \
    -q $min_quality \
    -F \
    4 - \
  | samtools \
    sort \
    --threads "${threads}" \
    - \
  > "${prefix}.sorted.bam"

rm "${reference}.trimmed.fa"

# Trim with ivar
echo "[2] Trimming with ivar"
samtools index "${prefix}.sorted.bam"

# samtools flagstat "${prefix}.sorted.bam"
ivar \
  trim \
  -e \
  -q 0 \
  -i "${prefix}.sorted.bam" \
  -b "${primer_bed_file}" \
  -p "${prefix}.ivar"

echo "[3] Sorting and indexing trimmed BAM"

samtools \
  sort \
  -@ "${threads}" \
  "${prefix}.ivar.bam" \
  > "${prefix}.sorted.bam"

samtools \
  index \
  "${prefix}.sorted.bam"

echo "[4] Generating pileup"
samtools \
  mpileup \
  --fasta-ref "${reference}" \
  --max-depth 0 \
  --count-orphans \
  --no-BAQ \
  --min-BQ 0 \
  "${prefix}.sorted.bam" \
  > "${prefix}.pileup"

echo "[5] Generating variants TSV"
ivar \
  variants \
  -p "${prefix}.ivar" \
  -t 0.6 \
  < "${prefix}.pileup"

# Generate consensus sequence with ivar
echo "[6] Generating consensus sequence"
ivar \
  consensus \
  -p "${prefix}".ivar \
  -m 1 \
  -t 0.6 \
  -n N \
  < "${prefix}.pileup"

sed \
  '/>/ s/$/ | One Codex consensus sequence/' \
  < "${prefix}.ivar.fa" \
  > "${prefix}.consensus.fa"


# Move some files around and clean up
mv "${prefix}.consensus.fa" "consensus.fa"
mv "${prefix}.ivar.tsv" "variants.tsv"
mv "${prefix}.sorted.bam" "covid19.bam"
mv "${prefix}.sorted.bam.bai" "covid19.bam.bai"
rm "${prefix}"*

echo "[ ] Finished!"
