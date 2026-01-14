process EXTRACT_CLUSTER {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/16/16fd0599cbc5e52a5ac51f8668ed2c6988b4f44d461606e37953afcd581cd52d/data'
        : 'community.wave.seqera.io/library/biopython_pandas_python:671653bb7f9c4d5b'}"

    input:
    tuple val(meta), path(clusters), path(seq), path(coverages)
    val module

    output:
    tuple val(meta), path('*_members.fa'), path('*_centroid.fa'), path('*.json'), emit: members_centroids
    tuple val(meta), path("*.clusters.tsv")                                     , emit: tsv
    tuple val(meta), path("*.summary_mqc.tsv")                                  , emit: summary
    path "versions.yml"                                                         , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix = task.ext.prefix ?: "${meta.id}"
    def args = task.ext.args ?: ''
    def coverages_arg = coverages ? "-d ${coverages}" : ""
    """
    extract_clust.py \\
        ${args} \\
        -m ${module} \\
        -c ${clusters} \\
        ${coverages_arg} \\
        -s ${seq} \\
        -p ${prefix}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version | sed 's/Python //g')
        pandas: \$(pip show pandas | grep Version | sed 's/Version: //g')
        biopython: \$(pip show biopython | grep Version | sed 's/Version: //g')
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    def args = task.ext.args ?: ''
    """
    touch ${prefix}_cl0_members.fa
    touch ${prefix}_cl0_centroid.fa
    cat <<-END_JSON > ${prefix}_cl0.json
    {
        "cluster_id": "cl0",
        "centroid": "stub_centroid",
        "cluster_size": 1,
        "cumulative_read_depth": 0.0,
        "external_reference": null,
        "members": ["stub_member"],
        "taxid": null
    }
    END_JSON
    touch ${prefix}.summary_mqc.tsv
    touch ${prefix}.clusters.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version | sed 's/Python //g')
        pandas: \$(pip show pandas | grep Version | sed 's/Version: //g')
        biopython: \$(pip show biopython | grep Version | sed 's/Version: //g')
    END_VERSIONS
    """
}
