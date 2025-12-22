include { CDHIT_CDHITEST   } from '../../../modules/nf-core/cdhit/cdhitest/main'
include { VSEARCH_CLUSTER  } from '../../../modules/nf-core/vsearch/cluster/main'
include { MMSEQS_CREATEDB  } from '../../../modules/nf-core/mmseqs/createdb/main'
include { MMSEQS_LINCLUST  } from '../../../modules/nf-core/mmseqs/linclust/main'
include { MMSEQS_CLUSTER   } from '../../../modules/nf-core/mmseqs/cluster/main'
include { MMSEQS_CREATETSV } from '../../../modules/nf-core/mmseqs/createtsv/main'
include { VRHYME_VRHYME    } from '../../../modules/nf-core/vrhyme/vrhyme/main'
include { MASH_DIST        } from '../../../modules/nf-core/mash/dist/main'
include { CLUSTY           } from '../../../modules/nf-core/clusty/main'

workflow FASTA_FASTQ_CLUST {
    take:
    ch_fasta_fastq     // channel: [ val(meta), [ fasta ], [ fastq ] ]
    cluster_method     // string
    identity_threshold // value: 0.85

    main:
    ch_versions = channel.empty()
    ch_fasta = ch_fasta_fastq.map { meta, fasta, _fastq -> [meta, fasta] }

    // cluster our reference hits and contigs should make this a subworkflow
    if (cluster_method == "vsearch") {
        VSEARCH_CLUSTER(ch_fasta)

        ch_clusters = VSEARCH_CLUSTER.out.uc
        ch_versions = ch_versions.mix(VSEARCH_CLUSTER.out.versions.first())
    }
    else if (cluster_method == "cdhitest") {
        if (identity_threshold < 0.80) {
            log.warn("cdhitest identity threshold is set to ${identity_threshold}, which is below the minimum threshold of 0.80.\n AUTOFIX: Defaulting to 0.80")
        }
        CDHIT_CDHITEST(ch_fasta)

        ch_clusters = CDHIT_CDHITEST.out.clusters
        ch_versions = ch_versions.mix(CDHIT_CDHITEST.out.versions.first())
    }
    else if (cluster_method == "mmseqs-linclust" || cluster_method == "mmseqs-cluster") {
        MMSEQS_CREATEDB(ch_fasta)
        ch_versions = ch_versions.mix(MMSEQS_CREATEDB.out.versions.first())

        if (cluster_method == "mmseqs-linclust") {
            MMSEQS_LINCLUST(MMSEQS_CREATEDB.out.db)
            ch_db_cluster = MMSEQS_LINCLUST.out.db_cluster
            ch_versions = ch_versions.mix(MMSEQS_LINCLUST.out.versions.first())
        }
        else {
            MMSEQS_CLUSTER(MMSEQS_CREATEDB.out.db)
            ch_db_cluster = MMSEQS_CLUSTER.out.db_cluster
            ch_versions = ch_versions.mix(MMSEQS_CLUSTER.out.versions.first())
        }

        ch_createtsv_input = ch_db_cluster
            .join(MMSEQS_CREATEDB.out.db, by: [0])
            .multiMap { meta, db_clus, db_in ->
                result: [meta, db_clus]
                query: [meta, db_in]
                target: [meta, db_in]
            }

        MMSEQS_CREATETSV(ch_createtsv_input.result, ch_createtsv_input.query, ch_createtsv_input.target)
        ch_clusters = MMSEQS_CREATETSV.out.tsv
        ch_versions = ch_versions.mix(MMSEQS_CREATETSV.out.versions.first())
    }
    else if (cluster_method == "vrhyme") {
        vhryme_in = ch_fasta_fastq.branch { meta, fasta, reads ->
            fasta: [meta, fasta]
            reads: [meta, reads]
        }
        VRHYME_VRHYME(vhryme_in.reads, vhryme_in.fasta)
        ch_clusters = VRHYME_VRHYME.out.membership
        ch_versions = ch_versions.mix(VRHYME_VRHYME.out.versions.first())
    }
    else if (cluster_method == "mash") {

        // Calculate distances
        MASH_DIST(ch_fasta)
        ch_versions = ch_versions.mix(MASH_DIST.out.versions.first())

        // Fix bug with clusty not accepting singletons
        ch_dist = MASH_DIST.out.dist
            .branch{ _meta, dist ->
                def line_count = dist.withInputStream { stream -> stream.readLines().take(3).size() }
                multiple: line_count > 2
                single: line_count <= 2 // if only two lines, then singleton cluster, no need to cluster
            }

        // Determine clusters from distances
        CLUSTY(ch_dist.multiple, [[:], []])
        ch_clusters = ch_dist.single.mix(CLUSTY.out.assignments)
    }

    emit:
    clusters = ch_clusters // channel: [ [ meta ], [ clusters ] ]
    versions = ch_versions // channel: [ versions.yml ]
}
