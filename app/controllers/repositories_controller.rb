class RepositoriesController < ApplicationController
  before_action :set_repository, only: %i[ show edit update destroy validate edit_strategy update_strategy sync detect_structure edit_authors update_authors edit_layout update_layout validate_layout ]

  # GET /repositories or /repositories.json
  def index
    @repositories = Repository.for_token(current_token_hash)
  end

  # GET /repositories/1 or /repositories/1.json
  def show
  end

  # GET /repositories/new
  def new
    @repository = Repository.new
  end

  # GET /repositories/1/edit
  def edit
  end

  # POST /repositories or /repositories.json
  def create
    @repository = Repository.new(repository_params)
    @repository.owner_token_hash = current_token_hash
    @repository.gitlab_endpoint = session[:gitlab_endpoint]

    respond_to do |format|
      if @repository.save
        format.html { redirect_to @repository, notice: "Repository was successfully created." }
        format.json { render :show, status: :created, location: @repository }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @repository.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /repositories/1 or /repositories/1.json
  def update
    # SVN URL이 변경되었는지 확인
    url_changed = @repository.svn_url != repository_params[:svn_url]
    
    respond_to do |format|
      if @repository.update(repository_params)
        # SVN URL이 변경되면 관련 정보 초기화 (migration_method는 유지)
        if url_changed
          @repository.update_columns(
            svn_structure: nil,
            authors_mapping: nil,
            layout_type: nil,
            custom_trunk_path: nil,
            custom_branches_path: nil,
            custom_tags_path: nil,
          )
          notice_message = "Repository URL이 변경되었습니다. SVN 구조를 다시 감지해주세요."
        else
          notice_message = "Repository was successfully updated."
        end
        
        format.html { redirect_to @repository, notice: notice_message }
        format.json { render :show, status: :ok, location: @repository }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @repository.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /repositories/1 or /repositories/1.json
  def destroy
    @repository.destroy!

    respond_to do |format|
      format.html { redirect_to repositories_path, status: :see_other, notice: "Repository was successfully destroyed." }
      format.json { head :no_content }
    end
  end

  # POST /repositories/1/validate
  def validate
    service = Repositories::ValidatorService.new(@repository)
    result = service.call

    respond_to do |format|
      format.json { render json: result }
    end
  end

  # GET /repositories/1/edit_strategy
  def edit_strategy
    @strategy_service = Repositories::MigrationStrategyService.new(@repository)
    
    # Convert Array format to String format for the form
    if @repository.authors_mapping.is_a?(Array)
      authors_text = @repository.authors_mapping.map do |author|
        "#{author['svn_name']} = #{author['git_name']} <#{author['git_email']}>"
      end.join("\n")
      @repository.authors_mapping = authors_text
    end
  end

  # PATCH /repositories/1/update_strategy
  def update_strategy
    @strategy_service = Repositories::MigrationStrategyService.new(@repository)
    
    if @strategy_service.update_strategy(strategy_params)
      errors = @strategy_service.validate_strategy
      
      if errors.empty?
        redirect_to @repository, notice: "Migration strategy updated successfully."
      else
        flash.now[:alert] = errors.join(", ")
        render :edit_strategy, status: :unprocessable_entity
      end
    else
      render :edit_strategy, status: :unprocessable_entity
    end
  end
  
  # POST /repositories/1/sync
  def sync
    # git-svn 방식으로 마이그레이션된 저장소만 증분 동기화 가능
    unless @repository.migration_method == 'git-svn'
      redirect_to @repository, alert: "증분 동기화는 Full Mode로 마이그레이션된 저장소에서만 사용 가능합니다"
      return
    end
    
    # Check for active jobs
    if @repository.has_active_job?
      redirect_to @repository, alert: "This repository already has an active job running."
      return
    end
    
    job_id = IncrementalSyncJob.perform_async(@repository.id)
    
    # Find the job created by IncrementalSyncJob
    job = @repository.jobs.order(created_at: :desc).first
    redirect_to job_path(job), notice: "Incremental sync job started successfully!"
  end
  
  # POST /repositories/1/detect_structure
  def detect_structure
    detector = Repositories::SvnStructureDetector.new(@repository)
    result = detector.call
    
    if result[:success]
      # layout_type도 함께 업데이트
      layout_type_mapping = {
        'standard' => 'standard',
        'partial_standard' => 'custom',
        'non_standard' => 'custom'
      }
      
      @repository.update!(
        svn_structure: result[:structure],
        authors_mapping: result[:authors],
        layout_type: layout_type_mapping[result[:structure][:layout]] || 'custom',
        latest_revision: result[:stats][:latest_revision],
        total_revisions: result[:stats][:latest_revision]  # SVN에서는 latest가 곧 total
      )
      
      # Prepare response data
      response_data = {
        success: true,
        structure: result[:structure],
        authors: result[:authors],
        stats: result[:stats],
        message: "SVN 구조가 성공적으로 감지되었습니다. #{result[:structure][:layout]} 레이아웃과 #{result[:authors].size}명의 작성자를 찾았습니다."
      }
      
      respond_to do |format|
        format.json { render json: response_data }
        format.html { redirect_to @repository, notice: response_data[:message] }
      end
    else
      error_message = case result[:error]
      when /authentication/i
        "SVN 저장소 인증에 실패했습니다. 인증 정보를 확인해주세요."
      when /not found/i, /does not exist/i
        "SVN URL이 올바르지 않거나 접근할 수 없습니다."
      when /timeout/i
        "연결 시간이 초과되었습니다. 네트워크 상태를 확인해주세요."
      else
        result[:error]
      end
      
      respond_to do |format|
        format.json { render json: { success: false, error: error_message }, status: :unprocessable_entity }
        format.html { redirect_to @repository, alert: "SVN 구조 감지 실패: #{error_message}" }
      end
    end
  end
  
  # GET /repositories/1/edit_authors
  def edit_authors
    # Ensure authors_mapping exists
    if @repository.authors_mapping.blank?
      # Try to detect structure first
      detector = Repositories::SvnStructureDetector.new(@repository)
      result = detector.call
      
      if result[:success]
        @repository.update!(authors_mapping: result[:authors])
      else
        # Create empty authors mapping
        @repository.update!(authors_mapping: [])
      end
    end
  end
  
  # PATCH /repositories/1/update_authors
  def update_authors
    authors_data = params[:authors] || {}
    updated_authors = []
    
    authors_data.each do |index, author_params|
      updated_authors << {
        'svn_name' => author_params[:svn_name],
        'git_name' => author_params[:git_name],
        'git_email' => author_params[:git_email]
      }
    end
    
    @repository.update!(authors_mapping: updated_authors)
    
    # Generate authors file if requested
    if params[:generate_file] == '1'
      generate_authors_file
    end
    
    redirect_to @repository, notice: "Authors mapping updated successfully."
  end
  
  # GET /repositories/1/edit_layout
  def edit_layout
    # 비표준 레이아웃인 경우에만 편집 가능
    unless @repository.svn_structure.present?
      redirect_to @repository, alert: "먼저 SVN 구조를 감지해주세요."
      return
    end
    
    svn_structure = @repository.parsed_svn_structure
    layout = svn_structure['layout']
    if layout == 'standard'
      redirect_to @repository, notice: "표준 레이아웃은 수정할 필요가 없습니다."
      return
    end
  end
  
  # PATCH /repositories/1/update_layout
  def update_layout
    layout_params = params.require(:repository).permit(
      :layout_type, :custom_trunk_path, :custom_branches_path, :custom_tags_path
    )
    
    if @repository.update(layout_params)
      # svn_structure 업데이트
      structure = @repository.svn_structure || {}
      structure['layout'] = layout_params[:layout_type]
      structure['custom_paths'] = {
        'trunk' => layout_params[:custom_trunk_path],
        'branches' => layout_params[:custom_branches_path],
        'tags' => layout_params[:custom_tags_path]
      }
      @repository.update!(svn_structure: structure)
      
      redirect_to @repository, notice: "레이아웃 구성이 저장되었습니다."
    else
      render :edit_layout
    end
  end
  
  # POST /repositories/1/validate_layout
  def validate_layout
    validator = Repositories::SvnLayoutValidator.new(
      @repository,
      params[:trunk_path],
      params[:branches_path],
      params[:tags_path]
    )
    
    result = validator.validate
    
    respond_to do |format|
      format.json { render json: result }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_repository
      @repository = Repository.for_token(current_token_hash).find(params[:id])
    rescue ActiveRecord::RecordNotFound
      redirect_to repositories_path, alert: "Repository not found or access denied"
    end

    # Only allow a list of trusted parameters through.
    def repository_params
      params.require(:repository).permit(:name, :svn_url, :auth_type, :username, :encrypted_password, :ssh_key, :branch_option, 
                                          :layout_type, :custom_trunk_path, :custom_branches_path, :custom_tags_path)
    end
    
    def strategy_params
      params.require(:repository).permit(
        :migration_method,
        :migration_type,
        :preserve_history,
        :authors_mapping,
        :ignore_patterns,
        :generate_gitignore,
        :commit_message_prefix,
        :gitlab_target_branch
      )
    end
    
    def generate_authors_file
      return unless @repository.authors_mapping.present?
      
      # Create directory for authors files
      authors_dir = Rails.root.join('tmp', 'authors_files')
      FileUtils.mkdir_p(authors_dir)
      
      # Generate authors file
      authors_file_path = authors_dir.join("#{@repository.id}_authors.txt")
      
      File.open(authors_file_path, 'w') do |file|
        @repository.authors_mapping.each do |author|
          file.puts "#{author['svn_name']} = #{author['git_name']} <#{author['git_email']}>"
        end
      end
      
      # Store the path for later use
      @repository.update!(authors_file_path: authors_file_path.to_s)
    end
end
