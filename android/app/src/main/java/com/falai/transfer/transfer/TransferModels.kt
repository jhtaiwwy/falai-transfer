package com.falai.transfer.transfer

enum class Direction { SEND, RECEIVE }

enum class TransferStatus { WAITING, TRANSFERRING, PAUSED, DONE, FAILED, CANCELED, REJECTED }

data class TransferProgress(
    val show: Boolean = false,
    val active: Boolean = false,
    val direction: Direction = Direction.SEND,
    val peerName: String = "",
    val status: TransferStatus = TransferStatus.WAITING,
    val currentFile: String = "",
    val fileIndex: Int = 0,
    val fileCount: Int = 0,
    val totalBytes: Long = 0,
    val transferredBytes: Long = 0,
    val speedBps: Double = 0.0,
    val etaSeconds: Long = 0,
    val error: String? = null,
)

data class IncomingRequest(
    val id: Long,
    val fromName: String,
    val fromIp: String,
    val fileCount: Int,
    val totalBytes: Long,
)
