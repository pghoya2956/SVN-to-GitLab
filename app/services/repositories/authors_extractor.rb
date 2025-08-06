class Repositories::AuthorsExtractor
  def initialize(repository)
    @repository = repository
  end
  
  def extract_all_authors
    Rails.logger.info "Extracting all authors from SVN repository..."
    
    authors = Set.new
    
    # Use svn log --xml to get all authors
    cmd = ['svn', 'log', '--xml', '--quiet', @repository.svn_url]
    
    # Add authentication if needed
    if @repository.auth_type == 'basic'
      cmd += ['--username', @repository.username] if @repository.username.present?
      cmd += ['--password', @repository.password] if @repository.password.present?
      cmd << '--non-interactive'
      cmd << '--trust-server-cert-failures=unknown-ca,cn-mismatch,expired,not-yet-valid,other'
    end
    
    output = []
    error = []
    
    Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
      output = stdout.read
      error = stderr.read
      
      unless wait_thr.value.success?
        Rails.logger.error "Failed to extract authors: #{error}"
        raise "Failed to extract authors from SVN: #{error}"
      end
    end
    
    # Parse XML to extract authors
    require 'nokogiri'
    doc = Nokogiri::XML(output)
    doc.xpath('//author').each do |author_node|
      author = author_node.text.strip
      authors.add(author) if author.present?
    end
    
    Rails.logger.info "Found #{authors.size} unique authors"
    authors.to_a.sort
  rescue => e
    Rails.logger.error "Error extracting authors: #{e.message}"
    []
  end
  
  def generate_authors_template(authors)
    template = []
    template << "# SVN to Git Author Mapping"
    template << "# Format: svn_username = Full Name <email@example.com>"
    template << "# Please edit each line with correct name and email"
    template << "#"
    
    # Merge with existing mapping
    existing_mapping = @repository.authors_mapping || {}
    
    authors.each do |author|
      if existing_mapping[author].present?
        # Use existing mapping
        template << "#{author} = #{existing_mapping[author]}"
      else
        # Generate default mapping
        default_email = "#{author.gsub(/[^a-zA-Z0-9]/, '')}@example.com"
        template << "#{author} = #{author} <#{default_email}>"
      end
    end
    
    template.join("\n")
  end
  
  def create_authors_file(job_id)
    authors = extract_all_authors
    return nil if authors.empty?
    
    template = generate_authors_template(authors)
    
    # Save to file
    dir = Rails.root.join('tmp', 'migrations', job_id.to_s)
    FileUtils.mkdir_p(dir)
    
    file_path = dir.join('authors.txt')
    File.write(file_path, template)
    
    Rails.logger.info "Created authors file at #{file_path}"
    file_path.to_s
  end
  
  def validate_authors_file(file_path)
    return false unless File.exist?(file_path)
    
    # Check if all authors have been edited (no @example.com)
    content = File.read(file_path)
    if content.include?('@example.com')
      Rails.logger.warn "Authors file still contains @example.com placeholders"
      return false
    end
    
    true
  end
end