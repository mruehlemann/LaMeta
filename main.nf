/*

LaMeta assembly and annotation pipeline by M. Rühlemann

*/

VERSION = "0.2"

logParams(params, "nextflow_parameters.txt")

// Header log info
log.info "========================================="
log.info "LaMeta assembly and annotation pipeline v${VERSION}"
log.info "Nextflow Version:	$workflow.nextflow.version"
log.info "Command Line:		$workflow.commandLine"
log.info "Author:		Malte Rühlemann"
log.info "========================================="
log.info "Starting at:		$workflow.start"

OUTDIR=file(params.outdir)
GROUP=file(params.groupfile)

READMINLEN = params.readminlen

BBWRAP = file(params.bbwrap)
BBDUK = file(params.bbduk)
BBMERGE = file(params.bbmerge)
REFORMAT = file(params.reformat)
ADAPTERS = file(params.adapters)
HSREF = file(params.hsref)

MEGAHIT=file(params.megahit)

SPADES=file(params.spades)
SPADES_kmers=params.spades_kmers

SAMTOOLS=file(params.samtools)

JGISUM=file(params.jgisum)
METABAT=file(params.metabat)
PRODIGAL=file(params.prodigal)
HMMSEARCH=file(params.hmmsearch)
MARKERS107=file(params.markers107hmm)
MARKERS40=file(params.markers40hmm)
PARALLEL=file(params.parallel)

CHECKM=file(params.checkm)
MAXBIN=file(params.maxbin)
MINCOMP=params.mincomp

GTDBTK=file(params.gtdbtk)

RSCRIPT=file(params.rscript)

PYENV3=params.pyenv3
PYENV2=params.pyenv2
DREP=file(params.drep)

PYTHON=params.python

FOLDER=file(params.folder)

startfrom = params.startfrom

/*
Channel is created from the files in the input folder given by --folder.
*/

Channel
  .fromFilePairs(FOLDER + "/*_R{1,2}_001.fastq.gz", flat: true)
  .ifEmpty { exit 1, "Could not find a matching input file" }
  .into { inputQC; inputParseGroupPre }

inputParseGroupPre.map{id, f1, f2 -> id}.set{inputParseGroup}

process parseGroup {

tag "${id}"

input:
val id from inputParseGroup

output:
set id, stdout into outputParseGroup

script:
"""
grep $id $GROUP | awk '{printf \$2}'
"""
}

/*
Mapping against PhiX and Host genome (default:human). Mapped reads/read-pairs (also discordantly)
are discarded.
*/
process runQC {

  scratch true

  tag "${id}"
  publishDir "${OUTDIR}/Samples/${id}/Decon", mode: 'copy'

  input:
  set id, file(left),file(right) from inputQC

  output:
  set id,file(left_clean),file(right_clean),file(unpaired_clean) into outputQC
  set id,file(finalstats) into outputQCstats

  script:

  left_trimmed = "tmp_" + id + "_R1.trimmed.fastq"
  right_trimmed = "tmp_" + id + "_R2.trimmed.fastq"
  unpaired_trimmed = "tmp_" + id + "_RU.trimmed.fastq"

  left_nophix = "tmp_" + id + "_R1.nophix.fastq"
  right_nophix = "tmp_" + id + "_R2.nophix.fastq"
  unpaired_nophix = "tmp_" + id + "_RU.nophix.fastq"

  left_decon = "tmp_" + id + "_R1.decon.fastq"
  right_decon = "tmp_" + id + "_R2.decon.fastq"
  unpaired_decon = "tmp_" + id + "_RU.decon.fastq"

  merged = "tmp_" + id + "_RU.merged.fastq"
  left_clean = id + "_R1.clean.fastq.gz"
  right_clean = id + "_R2.clean.fastq.gz"
  unpaired_clean = id + "_RU.clean.fastq.gz"

  finalstats = id +".stats.txt"

  if( startfrom > 0 )
    """
    cp ${OUTDIR}/Samples/${id}/Decon/$left_clean $left_clean
    cp ${OUTDIR}/Samples/${id}/Decon/$right_clean $right_clean
    cp ${OUTDIR}/Samples/${id}/Decon/$unpaired_clean $unpaired_clean
    touch $finalstats
    """
  else
    """
    ${REFORMAT} threads=${task.cpus} in=${left} in2=${right} 2>&1 >/dev/null | awk '{print "RAW "\$0}' | tee stats.txt 
    ${BBDUK} threads=${task.cpus} in=${left} in2=${right} out1=${left_trimmed} out2=${right_trimmed} outs=${unpaired_trimmed} ref=${ADAPTERS} ktrim=r k=23 mink=11 hdist=1 minlength=${READMINLEN} tpe tbo
    ${BBDUK} threads=${task.cpus} in=${left_trimmed} in2=${right_trimmed} k=31 ref=artifacts,phix ordered cardinality out1=${left_nophix} out2=${right_nophix} minlength=${READMINLEN}
    ${BBDUK} threads=${task.cpus} in=${unpaired_trimmed}  k=31 ref=artifacts,phix ordered cardinality out1=${unpaired_nophix} minlength=${READMINLEN}
    ${BBWRAP} -Xmx23g threads=${task.cpus} minid=0.95 maxindel=3 bwr=0.16 bw=12 quickmatch fast minhits=2 qtrim=rl trimq=20 minlength=${READMINLEN} in=${left_nophix},${unpaired_nophix} in2=${right_nophix},NULL path=${HSREF} outu1=${left_decon} outu2=${right_decon} outu=${unpaired_decon} 2>&1 >/dev/null | awk '{print "HOST "\$0}' | tee -a stats.txt 
    ${BBMERGE} threads=${task.cpus} in1=${left_decon} in2=${right_decon} out=${merged} outu1=${left_clean} outu2=${right_clean} mininsert=${READMINLEN} 2>&1 >/dev/null | awk '{print "MERGED "\$0}' | tee -a stats.txt
    cat ${merged} ${unpaired_decon} | gzip -c > ${unpaired_clean}
    ${REFORMAT} threads=${task.cpus} in=${unpaired_clean} 2>&1 >/dev/null | awk '{print "UNPAIRED "\$0}' | tee -a stats.txt
    ${REFORMAT} threads=${task.cpus} in1=${left_clean} in2=${right_clean}  2>&1 >/dev/null | awk '{print "PAIRED "\$0}' | tee -a stats.txt
    rm tmp*

    grep "RAW" stats.txt  | grep 'Input:' | awk '{print "READS RAW "\$3/2}' | tee $finalstats
    grep "HOST" stats.txt | grep "Reads Used:"  | awk '{printf \$4" "}' | awk '{print "READS BIO "\$1/2 + \$2}' | tee -a $finalstats
    egrep "^UNPAIRED" stats.txt  | grep 'Input:' | awk '{print \$3}' | awk '{print "READS CLEAN_UNPAIRED "\$1}' | tee -a $finalstats
    egrep "^PAIRED" stats.txt  | grep 'Input:' | awk '{print \$3}' | awk '{print "READS CLEAN_PAIRED "\$1}' | tee -a $finalstats
    grep "RAW" stats.txt  | grep 'Input:' | awk '{print "BASES RAW "\$5}' | tee -a $finalstats
    egrep "^UNPAIRED" stats.txt  | grep 'Input:' | awk '{print "BASES CLEAN_UNPAIRED "\$5}' | tee -a $finalstats
    egrep "^PAIRED" stats.txt  | grep 'Input:' | awk '{print "BASES CLEAN_PAIRED "\$5}' | tee -a $finalstats

    """
}

/*
Co assembly within the groups given in groupfile.
*/
outputQC.into{inputSpades; inputSpadesBackmap; inputCoAssemblyPre}
outputParseGroup.into{outputParseGroup1; outputParseGroup2; outputParseGroup3 }

outputParseGroup1.join(inputCoAssemblyPre).map{id, group, left_clean, right_clean, unpaired_clean -> [group, id, left_clean, right_clean, unpaired_clean]}.set{inputCoAssembly}
inputCoAssembly.groupTuple().into{ inputCoAssemblyByGroup; inputBackmapMegahit }
process runCoAssembly {

  scratch true

  tag "${group}"
  publishDir "${OUTDIR}/CoAssembly/${group}", mode: 'copy'

  input:
  set group, id, file(left_clean), file(right_clean), file(unpaired_clean) from inputCoAssemblyByGroup

  output:
  set group, file(outcontigs), file(megahitlog) into outCoAssembly

  script:
  outcontigs = group + ".final_contigs.fasta"
  megahitlog = group + ".megahit.log"

  if( startfrom > 1 )
  """
  cat ${OUTDIR}/CoAssembly/${group}/$outcontigs | awk -v group=$group '/^>/{print ">Megahit_"group"_contig_"++i; next}{print}' > $outcontigs
  cp ${OUTDIR}/CoAssembly/${group}/$megahitlog $megahitlog
  """

  else
  """
  echo $left_clean > out
  echo $right_clean >> out
  echo $unpaired_clean >> out

  awk '
  {
      for (i=1; i<=NF; i++)  {
          a[NR,i] = \$i
      }
  }
  NF>p { p = NF }
  END {
      for(j=1; j<=p; j++) {
          str=a[1,j]
          for(i=2; i<=NR; i++){
              str=str" "a[i,j];
          }
          print str
      }
  }' out > tmp1

  awk '{printf " -1 " \$1 " -2 " \$2 " -r " \$3}' tmp1 > tmp

  $MEGAHIT \$(cat tmp | tr -d '\n') --num-cpu-threads ${task.cpus} --presets meta-large -o megahit_out --mem-flag 2 --verbose
  cat megahit_out/final.contigs.fa | cut -d ' ' -f 1 | awk -v group=$group '/^>/{print ">Megahit_"group"_contig_"++i; next}{print}' > $outcontigs
  mv megahit_out/log $megahitlog
  rm -r megahit_out
  """
}

/*
Single-samples metagenome assembly with spades
*/
process runSpades {

  scratch true

  tag "${id}"
  publishDir "${OUTDIR}/Samples/${id}/Spades", mode: 'copy'

  input:
  set id, file(left_clean), file(right_clean), file(unpaired_clean) from inputSpades

  output:
  set id, file(outcontigs) into outputSpades

  script:
  outcontigs = id + ".spades_contigs.fasta"

  if( startfrom > 1 )
  """
  awk -v id=$id '/^>/{print ">Spades_"id"_contig_"++i; next}{print}' ${OUTDIR}/Samples/${id}/Spades/$outcontigs > $outcontigs
  """

  else
  """
  module load Spades/3.9.0
  $SPADES --meta --pe1-1 $left_clean --pe1-2 $right_clean --pe1-s $unpaired_clean -k $SPADES_kmers -o spades_out -t ${task.cpus}
  awk -v id=$id '/^>/{print ">Spades_"id"_contig_"++i; next}{print}' spades_out/scaffolds.fasta > $outcontigs
  rm -r spades_out
  """
}


/*
Backmapping to spades assembly and contig abundance estimation
*/
outputSpades.into{inputSpadesBackmapContigs; inputSpadesMaxbin; inputSpadesMarkergenes; inputSpadesRefine}
inputSpadesBackmap.join(inputSpadesBackmapContigs).set { inputSpadesBackmapWithContigs}

process runSpadesBackmap {

  scratch true

  tag "${id}"
  publishDir "${OUTDIR}/Samples/${id}/Spades", mode: 'copy'

  input:
  set id, file(left_clean), file(right_clean), file(unpaired_clean), file(spadescontigs) from inputSpadesBackmapWithContigs

  output:
  set id, file(outdepth) into outputSpadesBackmap

  script:
  outdepth = id + ".depth.txt"
  if( startfrom > 2 )
  """
  cp ${OUTDIR}/Samples/${id}/Spades/$outdepth $outdepth
  """

  else
  """
  module load Java/1.8.0
  module load BBMap/37.88
  module load Samtools/1.5
  ${BBWRAP} -Xmx60g in=$left_clean,$unpaired_clean in2=$right_clean,NULL ref=$spadescontigs t=${task.cpus} out=tmp.sam kfilter=22 subfilter=15 maxindel=80
  $SAMTOOLS view -u tmp.sam | $SAMTOOLS sort -m 54G -@ 3 -o tmp_final.bam
  $JGISUM --outputDepth $outdepth tmp_final.bam
  rm tmp*
  rm -r ref
  """
}

/*
Single-sample binning with Maxbin2
*/
inputSpadesMaxbin.join(outputSpadesBackmap).into {inputMetabat; inputMaxbin; inputMaxbin40}

process runMaxbin {

  scratch true

  tag "${id}"
  publishDir "${OUTDIR}/Samples/${id}/Maxbin", mode: 'copy'

  input:
  set id, file(spadescontigs), file(depthfile) from inputMaxbin

  output:
  set id, file(binfolder) into outputMaxbinSamples

  script:
  binfolder = id + "_maxbin_bins"
  if( startfrom > 2 )
  """
  cp -r ${OUTDIR}/Samples/${id}/Maxbin/$binfolder $binfolder
  """

  else
  """
  module load Prokka/1.11

  tail -n+2 $depthfile | cut -f 1,3 > maxbin.cov
  mkdir $binfolder
(
  set -Ee
  function _catch {
    touch summary.txt
    echo "exception caught"
    exit 0
}
  trap _catch ERR
  $MAXBIN -contig $spadescontigs -abund maxbin.cov -out $binfolder/${id}.bin -thread ${task.cpus}
)

  """
}


process runMaxbin40 {

  scratch true

  tag "${id}"
  publishDir "${OUTDIR}/Samples/${id}/Maxbin40", mode: 'copy'

  input:
  set id, file(spadescontigs), file(depthfile) from inputMaxbin40

  output:
  set id, file(binfolder) into outputMaxbin40Samples

  script:
  binfolder = id + "_maxbin40_bins"
  if( startfrom > 2 )
  """
  cp -r ${OUTDIR}/Samples/${id}/Maxbin40/$binfolder $binfolder
  """

  else
  """
  module load Prokka/1.11

  tail -n+2 $depthfile | cut -f 1,3 > maxbin.cov
  mkdir $binfolder
  mkdir workfolder
  mkdir tmp_workfolder
(
  set -Ee
  function _catch {
    touch summary.txt
    echo "exception caught"
    exit 0
}
  trap _catch ERR
  $MAXBIN -contig $spadescontigs -abund maxbin.cov -out $binfolder/${id}.bin40 -thread ${task.cpus} -markerset 40
)

  """
}


process runMetabat {

  scratch true

  tag "${id}"
  publishDir "${OUTDIR}/Samples/${id}/Metabat", mode: 'copy'

  input:
  set id, file(spadescontigs), file(depthfile) from inputMetabat

  output:
  set id, file(binfolder) into outputMetabatSamples

  script:
  binfolder = id + "_metabat_bins"

  if( startfrom > 2 )
  """
  cp -r ${OUTDIR}/Samples/${id}/Metabat/$binfolder $binfolder
  """

  else
  """
  module load Prokka/1.11
  mkdir $binfolder
  $METABAT -i $spadescontigs -a $depthfile -o $binfolder/${id}.metabat.bin -t ${task.cpus}
  """
}

process runSpadesMarkergenes {

  scratch true

  tag "${id}"
  publishDir "${OUTDIR}/Samples/${id}/SpadesMarkergenes", mode: 'copy'

  input:
  set id, file(spadescontigs) from inputSpadesMarkergenes

  output:
  set id, file(markergenes) into outputSpadesMarkergenes

  script:
  markergenes = id + "_markergenes.txt"

  if( startfrom > 2 )
  """
  cp -r ${OUTDIR}/Samples/${id}//SpadesMarkergenes/$markergenes $markergenes
  """

  else
  """
  module load Prokka/1.11
  mkdir tmp
  cp $spadescontigs tmp
  perlbrew exec --with perl-5.12.3 $GTDBTK identify --genome_dir tmp -x fasta --cpus ${task.cpus} --out_dir markers
  cat markers/marker_genes/*/*tophit.tsv | grep -v hits | tr "," "\t" | cut -d ';' -f 1 > $markergenes
  """
}

inputSpadesRefine.join(outputSpadesMarkergenes).join(outputMaxbinSamples).join(outputMaxbin40Samples).join(outputMetabatSamples).into{ SamplesAllbins; testtest}
testtest.println()

process runSpadesRefine {

  tag "${id}"
  publishDir "${OUTDIR}/Samples/${id}/ContigsRefined", mode: 'copy'

  input:
  set id, file(spadescontigs), file(markergenes), file(binmaxbin), file(binmaxbin40), file(binmetabat) from SamplesAllbins

  output:
  set id, file(refinedcontigsout) into SampleRefinedContigs

  script:
  refinedcontigsout = id + "_refined"

  if( startfrom > 3 )
  """
  cp -r ${OUTDIR}/Samples/${id}//ContigsRefined/$refinedcontigsout $refinedcontigsout
  """

  else
  """
  module load R/3.4.0
  mkdir $refinedcontigsout
  grep '>' ${binmaxbin}/*fasta | tr ':' ' ' | tr -d '>'  | cut -d '/' -f 2 > btc.txt
  grep '>' ${binmaxbin40}/*fasta | tr ':' ' ' | tr -d '>'  | cut -d '/' -f 2 >> btc.txt
  grep '>' ${binmetabat}/*fa | tr ':' ' ' | tr -d '>'  | cut -d '/' -f 2 >> btc.txt
  $RSCRIPT /ifs/data/nfs_share/sukmb276/github/LaMeta/DAS_Tool_ripoff.Rscript ${id} btc.txt ${markergenes} 
  $PYTHON /ifs/data/nfs_share/sukmb276/github/LaMeta/sort_into_bins.py ${id}.refined.contig_to_bin.out ${spadescontigs}
  mkdir bins
  mkdir -p $refinedcontigsout/bins
  mv ${id}_cleanbin_*.fasta bins
  checkm lineage_wf -t ${task.cpus} -x fasta --nt --tab_table -f ${id}.checkm.out bins checkm
  head -n 1 ${id}.checkm.out > $refinedcontigsout/${id}.checkm.out
  for good in \$(awk -F '\t' '{if(\$12 > 50 && \$1!="Bin Id") print \$1}' ${id}.checkm.out); do mv bins/\$good.fasta $refinedcontigsout/bins; grep -w \$good ${id}.checkm.out >> ${refinedcontigsout}/${id}.checkm.out; done
  mv ${id}.refined* $refinedcontigsout
  """
}

























/*
Backmapping to Megahit groupwise co-assembly
*/
outCoAssembly.into{ inputContigsBackmapMegahit; inputContigsMegahitMaxbin; inputContigsMegahitMetabat; inputMegahitMarkergenes; inputMegahitRefine }
inputBackmapMegahit.transpose().combine(inputContigsBackmapMegahit, by: 0) .set { inputBackmapCoassemblyT }

process runCoassemblyBackmap {

  scratch true

  tag "${group}-${id}"
  publishDir "${OUTDIR}/CoAssembly/${group}/Backmap", mode: 'copy'

  input:
  set group, id, file(left_clean), file(right_clean), file(unpaired_clean), file(megahitcontigs), file(megahitlog) from inputBackmapCoassemblyT

  output:
  set group, file(bamout) into outMegahitBackmap

  script:
  bamout = id + ".megahit.final.bam"

  if( startfrom > 2 )
  """
  cp ${OUTDIR}/CoAssembly/${group}/Backmap/$bamout $bamout
  """

  else
  """
  module load Java/1.8.0
  module load BBMap/37.88
  module load Samtools/1.5
  ${BBWRAP} -Xmx60g in=$left_clean,$unpaired_clean in2=$right_clean,NULL ref=$megahitcontigs t=${task.cpus} out=tmp_sam.gz kfilter=22 subfilter=15 maxindel=80
  $SAMTOOLS view -u tmp_sam.gz | $SAMTOOLS sort -m 54G -@ 3 -o $bamout
  rm tmp*
  rm -r ref
  """
}

/*
Contig abundance estimation for co-assemblies
*/
outMegahitBackmap.groupTuple().set { inputCollapseBams }
process runCollapseBams {

  tag "${group}"
  publishDir "${OUTDIR}/CoAssembly/${group}/Backmap", mode: 'copy'

  input:
  set group, file(bams) from inputCollapseBams

  output:
  set group, file(depthfile) into coassemblyDepth
  set group, file(abufolder) into coassemblyAbufolder

  script:
  depthfile = group + "_depth.txt"
  abufolder = group + "_abufiles"

  if( startfrom > 2 )
  """
  cp ${OUTDIR}/CoAssembly/${group}/Backmap/$depthfile $depthfile
  cp -r ${OUTDIR}/CoAssembly/${group}/Backmap/$abufolder $abufolder
  """

  else
  """
  $JGISUM --outputDepth $depthfile $bams
  ncol=\$(head -n 1 $depthfile | awk '{print NF}')
  mkdir $abufolder
  for i in \$(seq 4 2 \$ncol); do
  name=\$(head -n 1 $depthfile | cut -f \$i | cut -d "." -f 1)
  cut -f  1,\$i $depthfile | tail -n+2 > $abufolder/\${name}.out
  done
  """
}

/*
Co-assembly binning with Maxbin2
*/
coassemblyAbufolder.join(inputContigsMegahitMaxbin).into{ inputMegahitMaxbin; inputMegahitMaxbin40 }
process runMegahitMaxbin {

  scratch true

  cpus 20
  memory 240.GB

  tag "${group}"
  publishDir "${OUTDIR}/CoAssembly/${group}/Maxbin", mode: 'copy'

  input:
  set group, file(inputfolder), file(megahitcontigs), file(megahitlog)  from inputMegahitMaxbin

  output:
  set group, file(binfolder) into outputMegahitMaxbin

  script:
  binfolder = group + "_maxbin_bins"

  if( startfrom > 2 )
  """
  cp -r ${OUTDIR}/CoAssembly/${group}/Maxbin/$binfolder $binfolder
  """

  else
  """
  module load Prokka/1.11

  ls ${inputfolder}/*.out > abufiles.txt
  mkdir $binfolder
  $MAXBIN -contig $megahitcontigs -abund_list abufiles.txt -out $binfolder/${group}.maxbin.bin -thread ${task.cpus}

  """
}

process runMegahitMaxbin40 {

  scratch true  

  cpus 20
  memory 240.GB

  tag "${group}"
  publishDir "${OUTDIR}/CoAssembly/${group}/Maxbin40", mode: 'copy'

  input:
  set group, file(inputfolder), file(megahitcontigs), file(megahitlog)  from inputMegahitMaxbin40

  output:
  set group, file(binfolder) into outputMegahitMaxbin40

  script:
  binfolder = group + "_maxbin40_bins"

  if( startfrom > 2 )
  """
  cp -r ${OUTDIR}/CoAssembly/${group}/Maxbin40/$binfolder $binfolder
  """

  else
  """
  module load Prokka/1.11

  ls ${inputfolder}/*.out > abufiles.txt
  mkdir $binfolder
  $MAXBIN -contig $megahitcontigs -abund_list abufiles.txt -out $binfolder/${group}.maxbin.bin40 -thread ${task.cpus} -markerset 40

  """
}


/*
Co-assembly binning with Metabat
*/
coassemblyDepth.join(inputContigsMegahitMetabat).set{ inputMegahitMetabat }
process runMegahitMetabat {

  scratch true

  tag "${group}"
  publishDir "${OUTDIR}/CoAssembly/${group}/Metabat", mode: 'copy'

  input:
  set group, file(inputdepth), file(megahitcontigs), file(megahitlog) from inputMegahitMetabat

  output:
  set group, file(binfolder) into outputMegahitMetabat

  script:
  binfolder = group + "_metabat_bins"

  if( startfrom > 2 )
  """
  cp -r ${OUTDIR}/CoAssembly/${group}/Metabat/$binfolder $binfolder
  """

  else

  """
  module load Prokka/1.11

  mkdir $binfolder
  $METABAT -i $megahitcontigs -a $inputdepth -o $binfolder/${group}.metabat.bin -t ${task.cpus}

  """
}


process runMegahitMarkergenes {

  scratch true

  tag "${group}"
  publishDir "${OUTDIR}/CoAssembly/${group}/MegahitMarkergenes", mode: 'copy'

  input:
  set group, file(megahitcontigs), file(megahitlog) from inputMegahitMarkergenes

  output:
  set group, file(markergenes) into outputMegahitMarkergenes

  script:
  markergenes = group + "_markergenes.txt"

  if( startfrom > 2 )
  """
  cp -r ${OUTDIR}/CoAssembly/${group}//MegahitMarkergenes/$markergenes $markergenes
  """

  else
  """
  module load Prokka/1.11
  mkdir tmp
  cp $megahitcontigs tmp
  perlbrew exec --with perl-5.12.3 $GTDBTK identify --genome_dir tmp -x fasta --cpus ${task.cpus} --out_dir markers
  cat markers/marker_genes/*/*tophit.tsv | grep -v hits | tr "," "\t" | cut -d ';' -f 1 > $markergenes
  rm -r tmp
  """
}

inputMegahitRefine.join(outputMegahitMarkergenes).join(outputMegahitMaxbin).join(outputMegahitMaxbin40).join(outputMegahitMetabat).into{ MegahitAllbins; testtest2}
testtest2.println()

process runMegahitRefine {

  tag "${group}"
  publishDir "${OUTDIR}/CoAssembly/${group}/ContigsRefined", mode: 'copy'

  input:
  set group, file(megahitcontigs), file(megahitlog), file(markergenes), file(binmaxbin), file(binmaxbin40), file(binmetabat) from MegahitAllbins

  output:
  set group, file(refinedcontigsout) into MegahitRefinedContigs

  script:
  refinedcontigsout = group + "_refined"

  if( startfrom > 3 )
  """
  cp -r ${OUTDIR}/CoAssembly/${group}//ContigsRefined/$refinedcontigsout $refinedcontigsout
  """

  else
  """
  module load R/3.4.0
  mkdir $refinedcontigsout
  grep '>' ${binmaxbin}/*fasta | tr ':' ' ' | tr -d '>'  | cut -d '/' -f 2 > btc.txt
  grep '>' ${binmaxbin40}/*fasta | tr ':' ' ' | tr -d '>'  | cut -d '/' -f 2 >> btc.txt
  grep '>' ${binmetabat}/*fa | tr ':' ' ' | tr -d '>'  | cut -d '/' -f 2 >> btc.txt
  $RSCRIPT /ifs/data/nfs_share/sukmb276/github/LaMeta/DAS_Tool_ripoff.Rscript ${group} btc.txt ${markergenes}
  $PYTHON /ifs/data/nfs_share/sukmb276/github/LaMeta/sort_into_bins.py ${group}.refined.contig_to_bin.out ${megahitcontigs} 
  mkdir bins
  mkdir -p $refinedcontigsout/bins
  mv ${group}_cleanbin_*.fasta bins
  checkm lineage_wf -t ${task.cpus} -x fasta --nt --tab_table -f ${group}.checkm.out bins checkm
  head -n 1 ${group}.checkm.out > $refinedcontigsout/${group}.checkm.out
  for good in \$(awk -F '\t' '{if(\$12 > 50 && \$1!="Bin Id") print \$1}' ${group}.checkm.out); do mv bins/\$good.fasta $refinedcontigsout/bins; grep -w \$good ${group}.checkm.out >> $refinedcontigsout/${group}.checkm.out; done 
  mv ${group}.refined* $refinedcontigsout
  """
}




workflow.onComplete {
  log.info "========================================="
  log.info "Duration:		$workflow.duration"
  log.info "========================================="
}
//#############################################################################################################
//#############################################################################################################
//
// FUNCTIONS
//
//#############################################################################################################
//#############################################################################################################
// ------------------------------------------------------------------------------------------------------------
//
// Read input file and save it into list of lists
//
// ------------------------------------------------------------------------------------------------------------
def logParams(p, n) {
  File file = new File(n)
  file.write "Parameter:\tValue\n"
  for(s in p) {
     file << "${s.key}:\t${s.value}\n"
  }
}
