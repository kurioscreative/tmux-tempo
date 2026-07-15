# frozen_string_literal: true

# Stage gate runner: `ruby -Ilib -Itest test/run_all.rb`
Dir[File.join(__dir__, "test_*.rb")].sort.each { |f| require f }
