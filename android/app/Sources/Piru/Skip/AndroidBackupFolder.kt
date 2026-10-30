// The Android side of folder backup (Android/Backup/FolderBackup+Android.swift): the Storage
// Access Framework's folder picker, a persisted grant on the folder the user picks, and the
// reads and writes of the backup file inside it. A cloud folder (Google Drive, Dropbox,
// Nextcloud, OneDrive) is written by its provider's own app, so Piru needs no network access.
// The picked folder goes back to Swift through the bridged AndroidBackupFolderResults; file
// calls are synchronous and run on the caller's thread, which Swift keeps off the main one.
package piru.module

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import java.io.File

class BackupStageResult(val uri: String?, val error: String?)

class AndroidBackupFolder {
    companion object {
        private const val MIME_TYPE = "application/octet-stream"
        private const val GRANT = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION

        private var context: Context? = null
        private var pickLauncher: ActivityResultLauncher<Uri?>? = null

        /// Registers the folder picker, which Android allows only while the activity is created.
        @JvmStatic
        fun register(activity: ComponentActivity) {
            context = activity.applicationContext
            pickLauncher = activity.registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
                picked(activity, uri)
            }
        }

        /// Opens the folder picker.
        @JvmStatic
        fun pick(): Boolean {
            val launcher = pickLauncher ?: return false
            launcher.launch(null)
            return true
        }

        /// Whether Piru still holds its grant on the folder. The user can revoke it from the
        /// system settings, and uninstalling the provider's app revokes it too.
        @JvmStatic
        fun isAccessible(tree: String): Boolean {
            val context = context ?: return false
            val uri = Uri.parse(tree)
            return context.contentResolver.persistedUriPermissions.any { it.uri == uri && it.isWritePermission }
        }

        /// Gives up the grant on a folder Piru no longer backs up to.
        @JvmStatic
        fun release(tree: String) {
            val context = context ?: return
            try {
                context.contentResolver.releasePersistableUriPermission(Uri.parse(tree), GRANT)
            } catch (error: SecurityException) {
                // Already gone.
            }
        }

        /// Whether the folder holds a file called `name`.
        @JvmStatic
        fun exists(tree: String, name: String): Boolean {
            val context = context ?: return false
            return try {
                child(context, Uri.parse(tree), name) != null
            } catch (error: Exception) {
                false
            }
        }

        /// Copies the file `name` in the folder to `destinationPath`. Returns null on success,
        /// else why it failed.
        @JvmStatic
        fun read(tree: String, name: String, destinationPath: String): String? {
            val context = context ?: return "unavailable"
            return try {
                val document = child(context, Uri.parse(tree), name)
                    ?: throw IllegalStateException("The backup file is missing from the folder.")
                val input = context.contentResolver.openInputStream(document)
                    ?: throw IllegalStateException("The backup file could not be opened.")
                input.use { stream -> File(destinationPath).outputStream().use { stream.copyTo(it) } }
                null
            } catch (error: Exception) {
                error.localizedMessage ?: error.toString()
            }
        }

        /// Return the provider's actual URI separately from any error.
        @JvmStatic
        @Synchronized
        fun stage(tree: String, name: String, partialName: String, sourcePath: String): BackupStageResult {
            val context = context ?: return BackupStageResult(null, "unavailable")
            var partial: Uri? = null
            var complete = false
            return try {
                val created = DocumentsContract.createDocument(
                    context.contentResolver, folder(Uri.parse(tree)), MIME_TYPE, partialName
                ) ?: throw IllegalStateException("The folder refused a new file.")
                partial = created
                copy(context, File(sourcePath), created)
                complete = true
                val copies = completePartials(context, tree, name)
                copies.add(created.toString())
                savePartials(context, tree, name, copies)
                prunePartials(context, tree, name, keep = 2)
                BackupStageResult(created.toString(), null)
            } catch (error: Exception) {
                if (!complete) partial?.let { deleteChecked(context, it) }
                BackupStageResult(null, error.localizedMessage ?: error.toString())
            }
        }

        /// Called only after stage completed and closed the stream. A failed publish
        /// leaves its complete partial intact, including when the final name was lost.
        @JvmStatic
        @Synchronized
        fun publish(tree: String, name: String, partialUri: String, sourcePath: String): String? {
            val context = context ?: return "unavailable"
            val resolver = context.contentResolver
            var incompleteTarget: Uri? = null
            return try {
                val treeUri = Uri.parse(tree)
                val partial = Uri.parse(partialUri)
                val existing = child(context, treeUri, name)
                // Remove the recovery entry durably BEFORE its URI can become the final.
                // A later index-write failure must never make pruning delete that final.
                val pending = completePartials(context, tree, name)
                pending.remove(partialUri)
                savePartials(context, tree, name, pending)
                val renamed = try {
                    existing?.let {
                        if (!deleteChecked(context, it)) {
                            throw IllegalStateException("The previous backup could not be replaced.")
                        }
                    }
                    DocumentsContract.renameDocument(resolver, partial, name)
                } catch (error: Exception) {
                    android.util.Log.w("PiruBackup", "Rename failed; trying a copy.", error)
                    null
                }
                val published = if (renamed != null) {
                    renamed
                } else {
                    pending.add(partialUri)
                    savePartials(context, tree, name, pending)
                    val target = child(context, treeUri, name)
                        ?: DocumentsContract.createDocument(resolver, folder(treeUri), MIME_TYPE, name)
                        ?: throw IllegalStateException("The folder refused a new file.")
                    incompleteTarget = target
                    copy(context, File(sourcePath), target)
                    incompleteTarget = null
                    target
                }
                // The final is now complete. Cleanup failures must not turn it into a
                // failed publication; keep failed deletions in the ledger for a retry.
                try {
                    prunePartials(context, tree, name, keep = 0)
                    cleanupLegacyPartials(context, treeUri, name, published)
                } catch (error: Exception) {
                    android.util.Log.w("PiruBackup", "Partial cleanup failed.", error)
                }
                null
            } catch (error: Exception) {
                incompleteTarget?.let { deleteChecked(context, it) }
                error.localizedMessage ?: error.toString()
            }
        }

        // Persist actual URIs in creation order: provider names and directory visibility
        // are not reliable identifiers, and process restarts must not reset retention.
        private fun completePartials(context: Context, tree: String, name: String): MutableList<String> =
            (context.getSharedPreferences("piru-backup-partials", Context.MODE_PRIVATE)
                .getString(tree + "\n" + name, "") ?: "")
                .split('\n').filter { it.isNotEmpty() }.distinct().toMutableList()

        private fun savePartials(context: Context, tree: String, name: String, copies: List<String>) {
            if (!context.getSharedPreferences("piru-backup-partials", Context.MODE_PRIVATE).edit()
                .putString(tree + "\n" + name, copies.joinToString("\n")).commit()) {
                throw IllegalStateException("The recovery-copy index could not be saved.")
            }
        }

        private fun prunePartials(context: Context, tree: String, name: String, keep: Int) {
            val copies = completePartials(context, tree, name)
            for (uri in copies.dropLast(keep)) {
                if (deleteChecked(context, Uri.parse(uri))) copies.remove(uri)
            }
            savePartials(context, tree, name, copies)
        }

        private fun deleteChecked(context: Context, uri: Uri): Boolean = try {
            val deleted = DocumentsContract.deleteDocument(context.contentResolver, uri)
            if (!deleted) android.util.Log.w("PiruBackup", "Provider refused to delete a backup document: $uri")
            deleted
        } catch (error: Exception) {
            android.util.Log.w("PiruBackup", "Backup document deletion failed: $uri", error)
            false
        }

        // Old versions did not record URIs. Reclaim recognizable leftovers only after
        // a final backup is complete, never by assuming that an old partial is complete.
        private fun cleanupLegacyPartials(context: Context, tree: Uri, name: String, published: Uri) {
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                ?: throw IllegalStateException("The folder did not return a children URI.")
            val columns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val stale = mutableListOf<Uri>()
            val cursor = context.contentResolver.query(children, columns, null, null, null)
                ?: throw IllegalStateException("The folder could not be listed for cleanup.")
            cursor.use {
                while (it.moveToNext()) {
                    val label = it.getString(1) ?: continue
                    val id = it.getString(0) ?: continue
                    if (label.startsWith(name + ".") && label.endsWith(".partial")) {
                        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, id)
                        if (uri != null && uri != published) stale.add(uri)
                    }
                }
            }
            for (uri in stale) deleteChecked(context, uri)
        }

        private fun picked(activity: ComponentActivity, uri: Uri?) {
            if (uri == null) {
                AndroidBackupFolderResults.shared.didPick(null, null)
                return
            }
            try {
                activity.contentResolver.takePersistableUriPermission(uri, GRANT)
            } catch (error: SecurityException) {
                AndroidBackupFolderResults.shared.didPick(null, null)
                return
            }
            AndroidBackupFolderResults.shared.didPick(uri.toString(), displayName(activity, uri))
        }

        private fun folder(tree: Uri): Uri =
            DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                ?: throw IllegalStateException("The folder did not return a document URI.")

        /// The document called `name` directly inside the folder.
        private fun child(context: Context, tree: Uri, name: String): Uri? {
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                ?: throw IllegalStateException("The folder did not return a children URI.")
            val columns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val result = context.contentResolver.query(children, columns, null, null, null)
                ?: throw IllegalStateException("The folder could not be listed.")
            result.use { cursor ->
                while (cursor.moveToNext()) {
                    if (cursor.getString(1) == name) {
                        val id = cursor.getString(0) ?: continue
                        return DocumentsContract.buildDocumentUriUsingTree(tree, id)
                            ?: throw IllegalStateException("The folder did not return a document URI.")
                    }
                }
            }
            return null
        }

        private fun copy(context: Context, source: File, target: Uri) {
            val output = context.contentResolver.openOutputStream(target, "wt")
                ?: throw IllegalStateException("The backup file could not be written.")
            output.use { stream -> source.inputStream().use { it.copyTo(stream) } }
        }

        private fun displayName(context: Context, tree: Uri): String? =
            try {
                context.contentResolver.query(folder(tree), arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
                    ?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
            } catch (error: Exception) {
                null
            }
    }
}
