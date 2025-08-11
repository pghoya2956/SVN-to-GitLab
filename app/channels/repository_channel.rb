class RepositoryChannel < ApplicationCable::Channel
  def subscribed
    repository = Repository.find(params[:id])
    stream_from "repository_#{repository.id}"
  rescue ActiveRecord::RecordNotFound
    reject
  end

  def unsubscribed
    stop_all_streams
  end
end