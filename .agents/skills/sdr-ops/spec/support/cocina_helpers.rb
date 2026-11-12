# frozen_string_literal: true

# Builds geo DROs shaped like real ones (see purl.stanford.edu/bc641kr2427.json).
module CocinaHelpers
  DRUID = 'druid:bc641kr2427'
  COLLECTION = 'druid:nz187ct8959'

  def file_hash(name, mimetype:, use: 'master', preserve: true, shelve: true, publish: true, view: 'stanford',
                download: 'stanford', version: 1, sdr_generated: false)
    {
      type: Cocina::Models::ObjectType.file,
      externalIdentifier: "https://cocina.sul.stanford.edu/file/bc641kr2427-abc123/#{name}",
      label: name, filename: name, size: 10, version:, hasMimeType: mimetype, use:, sdrGeneratedText: sdr_generated,
      hasMessageDigests: [{ type: 'sha1', digest: Digest::SHA1.hexdigest(name) },
                          { type: 'md5', digest: Digest::MD5.hexdigest(name) }],
      access: { view:, download: },
      administrative: { publish:, sdrPreserve: preserve, shelve: }
    }
  end

  def shapefile_hashes(version: 1)
    [
      file_hash('rail.shp', mimetype: 'application/vnd.shp', version:),
      file_hash('rail.dbf', mimetype: 'application/vnd.dbf', version:),
      file_hash('rail.prj', mimetype: 'text/plain', version:),
      file_hash('rail.fgb', mimetype: 'application/vnd.fgb', use: 'derivative', preserve: false, sdr_generated: true,
                            version:)
    ]
  end

  def build_dro(druid: DRUID, version: 1, files: nil, member_of: [COLLECTION], file_sets: nil)
    bare = druid.delete_prefix('druid:')
    file_sets ||= [{ type: Cocina::Models::FileSetType.object,
                     externalIdentifier: "https://cocina.sul.stanford.edu/fileSet/#{bare}-abc123",
                     label: 'Object', version:, structural: { contains: files || shapefile_hashes(version:) } }]
    dro = Cocina::Models.build({
                                 type: Cocina::Models::ObjectType.geo, externalIdentifier: druid, version:,
                                 access: { view: 'stanford', download: 'stanford' },
                                 administrative: { hasAdminPolicy: 'druid:hv992ry2431' },
                                 description: { title: [{ value: 'Railways: China, 2010' }],
                                                purl: "https://purl.stanford.edu/#{bare}" },
                                 identification: { sourceId: 'test:1' },
                                 structural: { contains: file_sets, isMemberOf: member_of }
                               })
    Cocina::Models.with_metadata(dro, 'lock-1')
  end

  def all_files(cocina)
    cocina.structural.contains.flat_map { |fs| fs.structural.contains }
  end
end
