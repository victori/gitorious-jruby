# encoding: utf-8
#--
#   Copyright (C) 2011 Gitorious AS
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

module GraphsHelper
  include CommitsHelper

  def capillary_js_paths
    paths = %w[branch graph formatters/scale formatters/svg-data formatters/raphael].collect do |p|
      "lib/capillary/lib/capillary/#{p}"
    end

    ["lib/raphael/raphael-min.js",
     "lib/buster-core/lib/buster-core", "lib/buster-core/lib/buster-event-emitter",
     "lib/capillary/lib/capillary"] + paths
  end
end
