class AddCustomLayoutFieldsToRepositories < ActiveRecord::Migration[7.1]
  def change
    # 레이아웃 타입 추가 (standard, custom, flat)
    add_column :repositories, :layout_type, :string, default: 'standard' unless column_exists?(:repositories, :layout_type)
    
    # 커스텀 경로 필드 추가
    add_column :repositories, :custom_trunk_path, :string unless column_exists?(:repositories, :custom_trunk_path)
    add_column :repositories, :custom_branches_path, :string unless column_exists?(:repositories, :custom_branches_path)
    add_column :repositories, :custom_tags_path, :string unless column_exists?(:repositories, :custom_tags_path)
    
    # 인덱스 추가
    add_index :repositories, :layout_type unless index_exists?(:repositories, :layout_type)
  end
end