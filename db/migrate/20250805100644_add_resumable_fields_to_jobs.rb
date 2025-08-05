class AddResumableFieldsToJobs < ActiveRecord::Migration[7.1]
  def change
    # 작업 단계 추적
    add_column :jobs, :phase, :string, default: 'pending'
    add_column :jobs, :phase_details, :jsonb, default: {}
    
    # 재개 가능 여부
    add_column :jobs, :resumable, :boolean, default: false
    add_column :jobs, :checkpoint_data, :jsonb, default: {}
    add_column :jobs, :retry_count, :integer, default: 0
    
    # 인덱스 추가
    add_index :jobs, :phase
    add_index :jobs, :resumable
  end
end
