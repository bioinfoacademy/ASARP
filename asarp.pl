#!/usr/bin/perl -w
use strict;

require "fileParser.pl"; #sub's for input annotation files
require "snpParser.pl"; #sub's for snps
require "bedHandler.pl"; #for bed.sam

# set autoflush for error and output
select(STDERR);
$| = 1;
select(STDOUT);
$| = 1;

if(@ARGV < 2){
  print "USAGE: perl $0 output_file config_file [optional: parameter_file]\n";
  exit;
}

# input arguments: $outputFile--output, $configs--configuration file for input files, $params--configuration file for parameters
my ($outputFile, $configs, $params) = getArgs(@ARGV); 
#strand-specific setting is more related to file configs (data dependent)
my ($snpF, $bedF, $rnaseqF, $xiaoF, $splicingF, $estF, $STRANDFLAG) = getRefFileConfig($configs); # input annotation/event files
my ($POWCUTOFF, $SNVPCUTOFF, $FDRCUTOFF, $ASARPPCUTOFF, $NEVCUTOFFLOWER, $NEVCUTOFFUPPER, $ALRATIOCUTOFF) = getParameters($params); # parameters


# if strand-specific flag is set, need to get two separate SNV lists (+ and - respectively)
# the extra Rc (reference complement) references are for - strand if $STRANDFLAG is set
my ($snpRef, $snpRcRef, $pRef, $pRcRef) = (undef, undef, undef, undef);

if($STRANDFLAG){
  ($snpRef, $pRef) = initSnp($snpF, $POWCUTOFF, '+');
  ($snpRcRef, $pRcRef) = initSnp($snpF, $POWCUTOFF, '-');
  #print "SNV List: +\n";  printListByKey($snpRef, 'powSnps');  printListByKey($snpRef, 'snps');
  #print "SNV List: -\n";  printListByKey($snpRcRef, 'powSnps');  printListByKey($snpRcRef, 'snps');
  
  my @pList = @$pRef;
  my @pRcList = @$pRcRef;
  #merge two lists
  my @joinList = (@pList, @pRcList);
  $pRef = \@joinList; # renew the reference to be the full list
}else{
  ($snpRef, $pRef) = initSnp($snpF, $POWCUTOFF);
  #print "SNV List:\n";
  #printListByKey($snpRef, 'powSnps');  #printListByKey($snpRef, 'snps');
}

# suggested, get the Chi-Squared Test p-value cutoff from FDR ($FDRCUTOFF)
if(defined($FDRCUTOFF)){
  print "Calculating the Chi-Squared Test p-value cutoff for FDR <= $FDRCUTOFF...\n";
  if(defined($SNVPCUTOFF)){
    print "NOTE: user-provided p-value in config: $SNVPCUTOFF is ignored.\n";
  }
  ($SNVPCUTOFF) = fdrControl($pRef, $FDRCUTOFF, 0); #1--verbose
  print "Adjusted Chi-Squared Test p-value cutoff by FDR control: $SNVPCUTOFF\n\n";
}else{
  print "FDR control NOT used. User set Chi-Squared Test p-value cutoff: $SNVPCUTOFF\n";
}

print "Reading annotations and event-related files\n";
# read the transcript annotation file: same whether strand-specific flag is set or now
my $transRef = readTranscriptFile($xiaoF);
#printListByKey($transRef, 'trans'); #utility sub: show transcripts (key: trans)
my ($genesRef, $geneNamesRef) = getGeneIndex($transRef); #get indices of gene transcript starts and gene names
my $altRef = getGeneAltTransEnds($transRef); #get alternative initiation/termination (AI/AT) events from transcripts
#printAltEnds($altRef); #utility sub: show AI/AT events derived from transcripts
# read all annotations, optionally rna-seq and est, splicing events and compile them
my $allEventsListRef = readAllEvents($splicingF, $rnaseqF, $estF, $transRef, $geneNamesRef);
my $splicingRef = compileGeneSplicingEvents($genesRef, values %$allEventsListRef); #compile events from different sources

print "\nProcessing SNVs\n";
################################# strand specific ############################################
# uniform init vars: Rc version means the - strand
my ($geneSnpRef, $geneSnpRcRef, $snpEventsRef, $snpEventsRcRef) = (undef, undef, undef, undef);
my ($snpsNevRef, $snpsNevRcRef, $allAsarpsRef, $allAsarpsRcRef) = (undef, undef, undef, undef);

# the following are involved in strand-specific handling if flag is set
if(!$STRANDFLAG){
  ($geneSnpRef) = setGeneSnps($snpRef, $transRef);
  #print "Powerful Snvs: \n"; printGetGeneSnpsResults($geneSnpRef,'gPowSnps', $snpRef,'powSnps', 1); #$SNVPCUTOFF);
  #print "Ordinary Snvs: \n"; printGetGeneSnpsResults($geneSnpRef,'gSnps', $snpRef,'snps', 1);
  
  ($snpEventsRef) = setSnpEvents($geneSnpRef, $altRef, $splicingRef); #match snps with events
  #print "Pow Alt Init/Term: \n";  	#printSnpEventsResultsByType($snpEventsRef,'powSnpAlt'); 
  #print "Snp Alt Init/Term: \n";  	#printSnpEventsResultsByType($snpEventsRef,'snpAlt'); 
  #print "\nPow Splicing: \n";  	#printSnpEventsResultsByType($snpEventsRef,'powSnpSp'); 
  #print "Ord Splicing: \n";  		#printSnpEventsResultsByType($snpEventsRef,'snpSp'); 

  print "\n\nCalculating NEV\n";
  ($snpsNevRef) = filterSnpEventsWithNev($snpRef, $geneSnpRef, $snpEventsRef, $bedF, $allEventsListRef, $NEVCUTOFFLOWER, $NEVCUTOFFUPPER); 
  #print "Pow NEV Alt Init/Term: \n";  	#printSnpEventsResultsByType($snpsNevRef,'nevPowSnpAlt'); 
  #print "NEV Alt Init/Term: \n";  	#printSnpEventsResultsByType($snpsNevRef,'nevSnpAlt'); 
  #print "Pow NEV Splicing: \n";  	#printSnpEventsResultsByType($snpsNevRef,'nevPowSnpSp'); 
  #print "NEV Splicing: \n";  		#printSnpEventsResultsByType($snpsNevRef,'nevSnpSp'); 

  print "Processing ASE and ASARP SNVs\n";
  ($allAsarpsRef) = processASEWithNev($snpRef, $geneSnpRef, $snpsNevRef, $SNVPCUTOFF, $ASARPPCUTOFF, $ALRATIOCUTOFF);

}else{
  # the following requires strand-specific handling if flag is set
  print "Additional handling for the +/- SNVs for strand-specific setting\n";
  ($geneSnpRef) = setGeneSnps($snpRef, $transRef, '+');  #print "SNVs of the - strand:\n";
  ($geneSnpRcRef) = setGeneSnps($snpRcRef, $transRef, '-');
  #print "Powerful Snvs (+): \n";  printGetGeneSnpsResults($geneSnpRef,'gPowSnps', $snpRef,'powSnps', 1); #$SNVPCUTOFF);
  #print "Powerful Snvs (-): \n";  printGetGeneSnpsResults($geneSnpRcRef,'gPowSnps', $snpRcRef,'powSnps', 1); #$SNVPCUTOFF);
  
  # The setSnpEvents should only work on $geneSnpRef/$geneSnpRcRef which should be already strand specific so there is no change (need to confirm)
  ($snpEventsRef) = setSnpEvents($geneSnpRef, $altRef, $splicingRef);    
  ($snpEventsRcRef) = setSnpEvents($geneSnpRcRef, $altRef, $splicingRef); #match snps with events
  #print "Pow Alt Init/Term: \n";  printSnpEventsResultsByType($snpEventsRef,'powSnpAlt'); 
  #print "Snp Alt Init/Term: \n";  printSnpEventsResultsByType($snpEventsRef,'snpAlt');   print "Alt Init/Term of the - strand:\n"; 
  #print "Pow Alt Init/Term: \n";  printSnpEventsResultsByType($snpEventsRef,'powSnpAlt'); 
  #print "Snp Alt Init/Term: \n";  printSnpEventsResultsByType($snpEventsRef,'snpAlt'); 

  print "\n\nCalculating NEV (+ and - strands)\n";
  ($snpsNevRef) = filterSnpEventsWithNev($snpRef, $geneSnpRef, $snpEventsRef, $bedF, $allEventsListRef, $NEVCUTOFFLOWER, $NEVCUTOFFUPPER, '+'); 
  ($snpsNevRcRef) = filterSnpEventsWithNev($snpRcRef, $geneSnpRcRef, $snpEventsRcRef, $bedF, $allEventsListRef, $NEVCUTOFFLOWER, $NEVCUTOFFUPPER, '-'); 
  #print "Pow NEV Alt Init/Term: \n";  	printSnpEventsResultsByType($snpsNevRef,'nevPowSnpAlt'); 
  #print "NEV Alt Init/Term: \n";  	printSnpEventsResultsByType($snpsNevRef,'nevSnpAlt'); 
  #print "Pow NEV Splicing: \n";  	printSnpEventsResultsByType($snpsNevRef,'nevPowSnpSp'); 
  #print "NEV Splicing: \n";  		printSnpEventsResultsByType($snpsNevRef,'nevSnpSp'); 
  #print "- results\n";
  #print "Pow NEV Alt Init/Term: \n";  	printSnpEventsResultsByType($snpsNevRcRef,'nevPowSnpAlt'); 
  #print "NEV Alt Init/Term: \n";  	printSnpEventsResultsByType($snpsNevRcRef,'nevSnpAlt'); 
  #print "Pow NEV Splicing: \n";  	printSnpEventsResultsByType($snpsNevRcRef,'nevPowSnpSp'); 
  #print "NEV Splicing: \n";  		printSnpEventsResultsByType($snpsNevRcRef,'nevSnpSp'); 
  
  print "Processing ASE and ASARP SNVs (+ and - strands)\n";
  ($allAsarpsRef) = processASEWithNev($snpRef, $geneSnpRef, $snpsNevRef, $SNVPCUTOFF, $ASARPPCUTOFF, $ALRATIOCUTOFF);
  ($allAsarpsRcRef) = processASEWithNev($snpRcRef, $geneSnpRcRef, $snpsNevRcRef, $SNVPCUTOFF, $ASARPPCUTOFF, $ALRATIOCUTOFF);
  
  #merge + and - SNV results
  print "Merging +/- SNV results\n";
  my $mergedAsarpsRef = mergeASARP($allAsarpsRef, $allAsarpsRcRef);
  $allAsarpsRef = $mergedAsarpsRef; # finally only the ref is used
}


#print "\n";
my $outputASE = $outputFile.'.ase.prediction';
my $outputSnv = $outputFile.'.snv.prediction';
my $outputGene = $outputFile.'.gene.prediction';
my $outputControl = $outputFile.'.controlSNV.prediction'; # for detailed information if one would like
outputRawASARP($allAsarpsRef, 'ASEgene', $outputASE);
outputRawASARP($allAsarpsRef, 'ASARPgene', $outputGene);
outputRawASARP($allAsarpsRef, 'ASARPsnp', $outputSnv);
outputRawASARP($allAsarpsRef, 'ASARPcontrol', $outputControl); # can be commented out if one wants concise results

my $allNarOutput = formatOutputVerNAR($allAsarpsRef);
if(defined($outputFile)){
  my $isOpen = open(my $fp, ">", $outputFile);
  if(!$isOpen){
    print "Warning: cannot open file: $outputFile to write the predicted results; will print on screen instead\n";
    print $allNarOutput;
  }else{
    print $fp $allNarOutput;
    close($fp);
  }
}else{
  print $allNarOutput;
}

=head1 NAME

asarp.pl -- The new and improved ASARP pipeline to discover ASE/ASARP genes/SNVs, which now supports strand-specific RNA-Seq data. 

For details of the older version, refer to the paper: 
I<Li G, Bahn JH, Lee JH, Peng G, Chen Z, Nelson SF, Xiao X. Identification of allele-specific alternative mRNA processing via transcriptome sequencing, Nucleic Acids Research, 2012, 40(13), e104> and its Supplementary Materials. Link: http://nar.oxfordjournals.org/content/40/13/e104

G<img/Intro.png>

=head1 SYNOPSIS

 perl asarp.pl output_file config_file [optional: parameter_file] 

B<NEW>: the ASARP pipeline now supports strand-specific RNA-Seq data (which can be processed by the new pre-processing script: L<procReads>. One can set the optional strand-specific flag in the cnofig file. IMPORTANT: the strand-specific option does not work correctly on non-strand-specific data.

ARGUMENTS:

 config_file		the input configuration file which contains all the input file keys and their paths

OPTIONAL:

 parameter_file		the parameter configuration file which contains all the thresholds and cutoffs
 			if not input, the default.param file in the ASARP main program directory will be used

Details of the input config and parameter files can be found in the L<Files> page. For preparation of the input files used in C<config_file>, see the pre-processing section: L<rmDup>, L<mergeSam>, L<procReads>

=head2 OUTPUTS

C<output_file> is where the ASARP result summary is output, and meanwhile there will be 4 addtional detailed result files output:

=over 6

=item C<output_file.ase.prediction> 
-- the detailed results of (whole-gene-level) ASE patterns (exclusive to other ASARP patterns: AI, AS or AT)

=item C<output_file.gene.prediction> 
-- the detailed results of ASARP results (ASE patterns excluded) arranged by genes

=item C<output_file.snv.prediction> 
-- the detailed results of ASARP results (ASE patterns excluded) of each individual SNV

=item C<output_file.controlSNV.prediction> 
-- the control SNV information of each individual ASARP SNV

=back

=head2 -I USAGE

Because asarp.pl requires other perl files in the same folder to run, C<-I path> can be used if one would like to run ASARP elsewhere by adding its C<path>. 

 perl -I path path/asarp.pl output_file config_file parameter_file

Note that in such a case, one should be careful of the locations of the config and parameter files. Abosulute paths are suggested for the files in C<config_file>.

=head1 DESCRIPTION

The ASARP method is presented below:

=head2 OVERVIEW

The procedures (rules) for ASARP are illustrated in the following figure and terminology explained below:

G<img/ASARP_core.png>


There are basically 3 steps. 

1. parse the input files and compile alternative mRNA processing events. see outputs of L<procReads>

2. get the SNVs and match them with the events.

3. process ASARP (including ASE) patterns and output the formatted results.

=head2 TERMINOLOGY

The predictions that ASARP makes are desribed below:

Allele-Specific Expression (ASE)

=over 6

=item B<ASE>: a single SNV is called to have an ASE pattern (or simply ASE SNV) if its allelic ratio significally diverges from 0.5 (in other words 1:1 for Ref:Alt).

=back

Allele-Specific Alternative RNA Processing (B<ASARP>) types:

=over 6


=item B<ASAS>: Allele-Specific Alternative Splicing; 

=item B<ASTI>: Allele-Specific (5'-end) Transcriptional Initiation (or called ASAI Alternative Initiation); 

=item B<ASAP>: Allele-Specific (3'-end) Alternative Polyadenylation (or called ASAT Alternative Termination)

=back

How to categorize ASARP patterns into specific Allele-Specific AI/AS/AT and/or combinations of them depends on whether the candidate SNV locations are in internal exons/introns (AS) and/or alternative 3' or 5' UTRs (AI/AT). A complex ASARP gene is with ASARP SNVs in more than one categories. 

G<img/Types.png>

B<NEV>: Normalized Expression Value, a PSI (Percent Spliced-In) like value to measure whether an event (also alternatively processed region) is also alternatively processed according to RNA-Seq (gene expression). It is calculated as (note that in some events only C<NEV_gene> is available) 

=over 6

=item C<NEV_sp = min (NEV_flanking, NEV_gene)>, where

=item C<NEV_flanking = (# event_reads/event_length)/(# flanking_region_total_reads/flanking_region_total_length)>, and

=item C<NEV_gene = (# event_reads/event_length)/(# gene_constitutive_exon_reads/gene_constitutive_exon_length)>

=back

C<*_length> means the total number of positions within the * region with non-zero reads.

G<img/Event.png>

=head1 REQUIREMENT

C<Statistics::R>: has to be installed. See http://search.cpan.org/~fangly/Statistics-R/lib/Statistics/R.pm 

=head1 SEE ALSO

L<Overview>, L<fileParser>, L<snpParser>, L<MyConstants>

=head1 COPYRIGHT

This pipeline is free software; you can redistribute it and/or modify it given that the related works and authors are cited and acknowledged.

This program is distributed in the hope that it will be useful, but without any warranty; without even the implied warranty of merchantability or fitness for a particular purpose.

=head1 AUTHOR

Cyrus Tak-Ming CHAN

Xiao Lab, Department of Integrative Biology & Physiology, UCLA

=cut
