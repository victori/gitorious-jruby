#--
#   Copyright (C) 2008 Johan Sørensen <johan@johansorensen.com>
#   Copyright (C) 2008 David A. Cuadrado <krawek@gmail.com>
#
#   This program is free software: you can redistribute it and/or modify
#   it under the terms of the GNU Affero General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU Affero General Public License for more details.
#
#   You should have received a copy of the GNU Affero General Public License
#   along with this program.  If not, see <http://www.gnu.org/licenses/>.
#++

class CommitsController < ApplicationController
  before_filter :find_project_and_repository
  before_filter :check_repository_for_commits
  
  def index
    if params[:branch].blank?
      redirect_to repo_owner_path(@repository, :project_repository_commits_in_ref_path, @project, 
                      @repository, @repository.head_candidate.name)
      return
    end
    @git = @repository.git
    @ref, _ = branch_and_path(params[:branch], @git)
    if h = @git.get_head(@ref)
      head = h
    else
      commit = @git.commit(@ref)
      head = Grit::Head.new(commit.id_abbrev, commit)
    end
    @root = Breadcrumb::Branch.new(head, @repository)
    @commits = @repository.cached_paginated_commits(@ref, params[:page])
    @atom_auto_discovery_url = project_repository_formatted_commits_feed_path(@project, @repository, params[:branch], :atom)
    respond_to do |format|
      format.html
    end
  end

  def show
    @diffmode = params[:diffmode] == "sidebyside" ? "sidebyside" : "inline"
    @git = @repository.git
    @commit = @git.commit(params[:id])
    @root = Breadcrumb::Commit.new(:repository => @repository, :id => @commit.id_abbrev)
    @diffs = @commit.diffs
    @comment_count = @repository.comments.count(:all, :conditions => {:sha1 => @commit.id.to_s})
    @committer_user = User.find_by_email_with_aliases(@commit.committer.email)
    @author_user = User.find_by_email_with_aliases(@commit.author.email)
    @comments = @repository.comments.find_all_by_sha1(@commit.id, :include => :user)
    respond_to do |format|
      format.html
      format.diff  { render :text => @diffs.map{|d| d.diff}.join("\n"), :content_type => "text/plain" }
      format.patch { render :text => @commit.to_patch, :content_type => "text/plain" }
    end
  end
  
  def feed
    @git = @repository.git
    branch_ref = desplat_path(params[:branch])
    @commits = @repository.git.commits(branch_ref)
    respond_to do |format|
      format.html { redirect_to(project_repository_commits_in_ref_path(@project, @repository, params[:branch]))}
      format.atom
    end
  end
  
  protected
    
end
