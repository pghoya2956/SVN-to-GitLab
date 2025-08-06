class DestroyUserSystem < ActiveRecord::Migration[7.1]
  def change
    # 외래키 제약 먼저 제거
    if foreign_key_exists?(:repositories, :users)
      remove_reference :repositories, :user, foreign_key: true
    end
    
    if foreign_key_exists?(:jobs, :users)
      remove_reference :jobs, :user, foreign_key: true
    end
    
    # 새 컬럼 추가 (이미 없는 경우만)
    unless column_exists?(:repositories, :owner_token_hash)
      add_column :repositories, :owner_token_hash, :string
      add_index :repositories, :owner_token_hash
    end
    
    unless column_exists?(:repositories, :gitlab_endpoint)
      add_column :repositories, :gitlab_endpoint, :string, default: 'https://gitlab.com/api/v4'
    end
    
    unless column_exists?(:jobs, :owner_token_hash)
      add_column :jobs, :owner_token_hash, :string
      add_index :jobs, :owner_token_hash
    end
    
    # 기본값 설정 (임시)
    execute "UPDATE repositories SET owner_token_hash = 'migration_temp' WHERE owner_token_hash IS NULL"
    execute "UPDATE jobs SET owner_token_hash = 'migration_temp' WHERE owner_token_hash IS NULL"
    
    # 테이블 삭제
    drop_table :gitlab_tokens if table_exists?(:gitlab_tokens)
    drop_table :users if table_exists?(:users)
  end
end