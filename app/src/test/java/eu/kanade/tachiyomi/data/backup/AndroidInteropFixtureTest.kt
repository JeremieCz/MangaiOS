package eu.kanade.tachiyomi.data.backup

import eu.kanade.tachiyomi.data.backup.models.Backup
import eu.kanade.tachiyomi.data.backup.models.BackupChapter
import eu.kanade.tachiyomi.data.backup.models.BackupManga
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.protobuf.ProtoBuf
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * Contrat synthétique public partagé avec AndroidBackupDecoderTests sur iOS.
 * Aucune bibliothèque utilisateur ; ne modifie pas le comportement de l'application.
 */
@OptIn(ExperimentalSerializationApi::class)
class AndroidInteropFixtureTest {
    @Test
    fun `current Android serializer verifies signed varints and golden iOS fixture`() {
        val backup = Backup(
            listOf(
                BackupManga(source = -1L, url = "s", title = "T").apply {
                    dateAdded = 1000L
                    viewer = 2
                    chapters = listOf(
                        BackupChapter(url = "c", name = "C").apply {
                            read = true
                            bookmark = true
                            lastPageRead = 7L
                            sourceOrder = -2L
                        },
                    )
                },
            ),
        )
        val bytes = ProtoBuf.encodeToByteArray(Backup.serializer(), backup)
        val hex = bytes.joinToString("") { "%02x".format(it.toInt() and 0xff) }
        assertEquals(
            "0a3008ffffffffffffffffff011201731a015468e8077002820117" +
                "0a016312014320012801300750feffffffffffffffff01",
            hex,
        )
        val decoded = ProtoBuf.decodeFromByteArray(Backup.serializer(), bytes)
        assertEquals(-1L, decoded.backupManga.single().source)
        assertEquals(-2L, decoded.backupManga.single().chapters.single().sourceOrder)
        assertEquals(1000L, decoded.backupManga.single().dateAdded)
    }
}
