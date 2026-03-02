include { noBlastHitsToMultiQC  } from '../utils_nfcore_viralmetagenome_pipeline'
include { BLAST_BLASTN          } from '../../../modules/nf-core/blast/blastn/main'
include { BLAST_BLASTDBCMD      } from '../../../modules/nf-core/blast/blastdbcmd/main'
include { BLAST_FILTER          } from '../../../modules/local/blast_filter'

workflow FASTA_BLAST_REFSEL {
    take:
    ch_fasta          // channel: [ val(meta), path(fasta)]
    ch_blacklist      // channel: [ path(blacklist) ]
    ch_blast_db       // channel: [ val(meta), path(db) ]

    main:
    ch_versions = channel.empty()
    // Blast results, to a reference database, to find a complete genome that's already assembled
    BLAST_BLASTN(
        ch_fasta,
        ch_blast_db,
        [], // taxidlist
        [], // taxids
        []  // negative_tax
    )
    ch_versions = ch_versions.mix(BLAST_BLASTN.out.versions.first())

    ch_blast_txt = BLAST_BLASTN.out.txt.branch { _meta, txt ->
        no_hits: txt.countLines() == 0
        hits: txt.countLines() > 0
    }

    // Make a table of samples that did not have any blast hits
    ch_no_blast_hits = channel.empty()
    ch_no_blast_hits = ch_blast_txt.no_hits.join(ch_fasta)

    ch_no_blast_hits_mqc = noBlastHitsToMultiQC(ch_no_blast_hits,params.assemblers).collectFile(name:'samples_no_blast_hits_mqc.tsv')

    // Filter out false positve hits that based on query length, alignment length, identity, e-score & bit-score
    ch_input_blast_filter = ch_blast_txt.hits
        .join(ch_fasta, by: [0], remainder: true)
        .multiMap { meta, txt, fasta ->
            hits: [meta, txt ? txt : []]
            contigs: [meta, fasta]
        }

    BLAST_FILTER(
        ch_input_blast_filter.hits,
        ch_input_blast_filter.contigs,
        ch_blacklist,
    )
    ch_versions = ch_versions.mix(BLAST_FILTER.out.versions.first())

    // Extract matching reference sequences from the BLAST DB using filtered hit IDs
    // NEEDS SOME EXTRA WORK TO MAKE SURE IF NO HITS ARE FOUND, sample channels don't get discarded
    BLAST_BLASTDBCMD(
        BLAST_FILTER.out.hits
            .filter { _meta, hits -> hits.countLines() > 0 }
            .map { meta, hits -> [meta, '', hits] },
        ch_blast_db
    )

    // Concatenate contigs with extracted reference sequences per sample
    // using mix + collectFile following the nf-core pattern
    ch_to_concat = BLAST_FILTER.out.sequence     // [ meta, contigs.fa ]         - always present
        .mix(BLAST_BLASTDBCMD.out.fasta)          // [ meta, refs.fasta ]          - only for samples with hits
        .multiMap { meta, fasta ->
            metadata: [meta.id, meta]
            fastas:   [meta.id, fasta]
        }

    ch_fasta_ref_contigs = ch_to_concat.fastas
        .collectFile { id, fasta ->
            ["${id}_withref.fa", fasta]
        }
        .map { file ->
            def id = file.simpleName.replace('_withref', '')
            [id, file]
        }
        .join(ch_to_concat.metadata.unique())
        .map { _id, file, meta -> [meta, file] }

    emit:
    fasta_ref_contigs = ch_fasta_ref_contigs      // channel: [ val(meta), [ fasta ] ]
    no_blast_hits     = ch_no_blast_hits_mqc       // channel: [ val(meta), [ mqc ] ]
    versions          = ch_versions                // channel: [ versions.yml ]
}
