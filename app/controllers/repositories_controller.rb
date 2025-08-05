class RepositoriesController < ApplicationController
  before_action :set_repository, only: %i[ show edit update destroy validate edit_strategy update_strategy sync detect_structure edit_authors update_authors ]

  # GET /repositories or /repositories.json
  def index
    @repositories = current_user.repositories
  end

  # GET /repositories/1 or /repositories/1.json
  def show
  end

  # GET /repositories/new
  def new
    @repository = current_user.repositories.build
  end

  # GET /repositories/1/edit
  def edit
  end

  # POST /repositories or /repositories.json
  def create
    @repository = current_user.repositories.build(repository_params)

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
    respond_to do |format|
      if @repository.update(repository_params)
        format.html { redirect_to @repository, notice: "Repository was successfully updated." }
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
    unless @repository.enable_incremental_sync?
      redirect_to @repository, alert: "Incremental sync is not enabled for this repository"
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
      @repository.update!(
        svn_structure: result[:structure],
        authors_mapping: result[:authors]
      )
      
      respond_to do |format|
        format.json { render json: result }
        format.html { redirect_to @repository, notice: "SVN structure detected successfully. Found #{result[:structure][:layout]} layout with #{result[:authors].size} authors." }
      end
    else
      respond_to do |format|
        format.json { render json: { error: result[:error] }, status: :unprocessable_entity }
        format.html { redirect_to @repository, alert: "Failed to detect SVN structure: #{result[:error]}" }
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

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_repository
      @repository = current_user.repositories.find(params[:id])
    end

    # Only allow a list of trusted parameters through.
    def repository_params
      params.require(:repository).permit(:name, :svn_url, :auth_type, :username, :encrypted_password, :ssh_key, :branch_option, :enable_incremental_sync)
    end
    
    def strategy_params
      params.require(:repository).permit(
        :migration_method,
        :migration_type,
        :preserve_history,
        :authors_mapping,
        :ignore_patterns,
        :tag_strategy,
        :branch_strategy,
        :commit_message_prefix,
        :large_file_handling,
        :max_file_size_mb
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
