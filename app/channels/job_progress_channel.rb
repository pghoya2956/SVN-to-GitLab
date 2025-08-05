class JobProgressChannel < ApplicationCable::Channel
  def subscribed
    job = Job.find(params[:job_id])
    stream_for job
  end
  
  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end
end