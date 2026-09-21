# France encryption declaration for the provider release

The owner confirmed on 21 September 2026 that France stays in the planned distribution scope. [Issue #208](https://github.com/svoltolini/gumbo/issues/208) tracks the required declaration and review; [#198](https://github.com/svoltolini/gumbo/issues/198) separately tracks provider/device certification. Neither this document nor a successful build is encryption approval.

## Verified Apple requirement

App Store Connect's App Encryption Documentation questionnaire was completed through its France question for app `6814252548`. The selected algorithm answer is standard algorithms implemented outside/in addition to Apple's operating system, and France is selected. Apple requests a **French encryption declaration approval form** and will not save until a document is attached. No file has been uploaded or declaration submitted in this flow.

This is consistent with [Apple's published requirement](https://developer.apple.com/help/app-store-connect/reference/export-compliance-documentation-for-encryption/) for standard algorithms implemented outside the OS when distributing in France. The new SMB client contains bundled AES/CCM/CMAC, NTLMv2, hashing and key-derivation code. The broader technical description must also include the existing Swift BLAKE2b/Noise implementation and the Synology encryption using Apple frameworks; it must not describe the entire app as using only TLS or OS cryptography.

Do not restore a blanket `ITSAppUsesNonExemptEncryption = false`, claim an exemption based only on free distribution/open source, or remove France to bypass the owner's decision. The public TestFlight build `202609211143` does not contain the new SMB provider; this is not evidence that all existing application cryptography is OS-only or that a historical declaration has been reclassified.

## Preparation and owner fields

The correct form is [ANSSI Annex I for a cryptology product](https://cyber.gouv.fr/documents/330/crypto_declaration-demande_autorisation_operations_annexe1_v2.pdf). Annex II concerns a cryptology service. The original Annex I is a dynamic XFA PDF: generic PDF readers may show only an Adobe Reader compatibility notice. Do not claim a form is filled by changing ordinary PDF annotations.

The preparation pack provides French answers, an inventory of algorithms and key sizes, source/build provenance, a product description and connection guides. It is deliberately unsigned. Private owner details belong in the private filing packet, never in this repository or public issues.

The owner has confirmed personal filing and supplied identity/contact details; these are filled in the private preparation packet. Before signing, the declarant still needs to review the technical contact, requested supply/import operations, final app/build version and planned release date. Section A.2 is the individual route; company-only registration fields must not be fabricated. Ask ANSSI which supporting evidence it requires for a foreign individual. Section C's grand-public export classification is a distinct assertion and remains unselected until reviewed.

## Filing and review

The [ANSSI electronic procedure](https://cyber.gouv.fr/reglementation/reglementation-identite-confiance-numerique/controles-reglementaires-cryptographie/controle-moyen-de-cryptologie/controle-reglementaire-cryptographie-formulaires/) requests the electronic form, signed scan and supporting documents, sent to `controle@ssi.gouv.fr` using its formalities subject convention. The preparation packet uses `[formalités] Gumbo – Gumbo Music`. No email has been sent. The signature and submission of the legal attestation require the owner's review and authorization.

Keep these steps separate:

1. Completed, signed developer declaration and supporting documents.
2. ANSSI acknowledgement and dossier reference, followed by the applicable declaration attestation or decision.
3. Any separately requested export classification.
4. Apple's own documentation review and the resulting declaration association for each applicable build.

The [decree](https://www.legifrance.gouv.fr/loda/id/JORFTEXT000000646995/) provides a one-month advance-filing period for the declaration route under articles 4–5, with different rules for incomplete dossiers and other operations. This is not a universal approval deadline. [Apple's review](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation) is separate and case-by-case. Its published help does not explicitly guarantee that a self-signed form or receipt alone will be sufficient. Do not upload a draft as an approved declaration; retain ANSSI's response or get Apple's explicit guidance on acceptable evidence.

This engineering record does not decide a French, UK or US legal classification. Regulatory evidence and actual provider/device acceptance remain release gates even after the paperwork has been prepared.
