#!/usr/bin/env ruby

# 실행 중인 작업 모니터링 스크립트

require 'time'

def format_time(seconds)
  return "N/A" unless seconds && seconds > 0
  
  hours = seconds / 3600
  minutes = (seconds % 3600) / 60
  secs = seconds % 60
  
  if hours > 0
    "#{hours}h #{minutes}m"
  elsif minutes > 0
    "#{minutes}m #{secs}s"
  else
    "#{secs}s"
  end
end

def display_progress_bar(progress, width = 40)
  return "[" + " " * width + "]" unless progress
  
  filled = (progress * width / 100.0).round
  bar = "█" * filled + "░" * (width - filled)
  "[#{bar}]"
end

loop do
  system("clear") || system("cls")
  
  puts "=== SVN to GitLab 마이그레이션 모니터링 ==="
  puts "시간: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
  puts "=" * 60
  puts
  
  jobs = Job.includes(:repository).order(id: :desc).limit(10)
  
  jobs.each do |job|
    repo_name = job.repository&.name || "Unknown"
    status_color = case job.status
                   when 'completed' then "\e[32m" # 녹색
                   when 'failed' then "\e[31m"    # 빨강
                   when 'running' then "\e[33m"    # 노랑
                   else "\e[0m"                    # 기본
                   end
    
    puts "Job ##{job.id} - #{repo_name}"
    puts "상태: #{status_color}#{job.status}\e[0m"
    
    if job.running?
      progress = job.progress || 0
      puts "진행률: #{progress}% #{display_progress_bar(progress)}"
      
      if job.current_revision && job.total_revisions && job.total_revisions > 0
        puts "리비전: #{job.current_revision}/#{job.total_revisions}"
        
        if job.processing_speed && job.processing_speed > 0
          puts "처리 속도: #{job.processing_speed.round(1)} rev/s"
        end
        
        if job.eta_seconds && job.eta_seconds > 0
          puts "예상 완료: #{format_time(job.eta_seconds)}"
        end
      end
    elsif job.failed?
      error_preview = job.error_log&.lines&.last&.strip
      puts "오류: #{error_preview}" if error_preview
    elsif job.completed?
      if job.completed_at && job.started_at
        duration = job.completed_at - job.started_at
        puts "소요 시간: #{format_time(duration)}"
      end
    end
    
    puts "-" * 60
  end
  
  # 통계
  running_count = Job.where(status: 'running').count
  pending_count = Job.where(status: 'pending').count
  completed_count = Job.where(status: 'completed').count
  failed_count = Job.where(status: 'failed').count
  
  puts
  puts "통계: 실행중(#{running_count}) | 대기(#{pending_count}) | 완료(#{completed_count}) | 실패(#{failed_count})"
  puts
  puts "5초마다 새로고침... (Ctrl+C로 종료)"
  
  sleep 5
end