require 'csv'
require 'yaml'
require 'byebug'
require 'readline'
require 'terminal-table'
require 'terminal-table/import'
require 'colorize'

Exam = Struct.new(:exercises) do
  attr_reader :results
  def self.load(hash)
    exercises = {}
    hash.each do |exercise_id, questions_hash|
      exercises[exercise_id] = Exercise.load(exercise_id, questions_hash)
    end
    new(exercises)
  end

  def read(student_id)
    er = ExamResult.new(student_id, exercises.values.map(&:read).flatten)
    er.exam = self
    @results ||= []
    @results << er
    er
  end

  def questions
    exercises.values.map(&:questions).flatten
  end

  def tasks
    exercises.values.map(&:tasks).flatten
  end

  def columns
    tasks.map(&:global_id)
  end

  def read_results(results_file)
    @results = []
    return unless File.exist?(results_file)
    tasks_by_id = tasks.inject({}) do |sum, task|
      sum[task.global_id] = task
      sum
    end
    column_mapping = []
    CSV.foreach(results_file) do |row|
      if column_mapping.empty?
        _, *header = row
        header.each_with_index do |header_col, index|
          task = tasks_by_id[header_col]
          raise "No task with id #{header_col} found" unless task
          column_mapping << task
        end
      else
        student_id, *points = row
        task_results = []
        points.each_with_index do |point, index|
          task_results << TaskResult.new(column_mapping[index], point)
        end
        er = ExamResult.new(student_id, task_results)
        er.exam = self
        @results << er
      end
    end
  end

  def write(results_file)
    CSV.open(results_file, "wb") do |csv|
      csv << ['student'] + columns
      @results.each do |result|
        csv << result.to_csv_row
      end
    end
  end

  def print_table
    exercise_row = exercises.values.map do |exercise|
      {value: exercise.id, colspan: exercise.tasks.length, :alignment => :center, :border_x => "="}
    end
    questions_row = exercises.values.map do |exercise|
      exercise.questions.values.map do |question|
        {value: question.id, colspan: question.tasks.length, :alignment => :center}
      end
    end.flatten
    task_name_row = exercises.values.map do |exercise|
      exercise.questions.values.map do |question|
        question.tasks.values.map do |task|
          {value: task.id, :alignment => :center}
        end
      end.flatten
    end.flatten

    task_value_row = exercises.values.map do |exercise|
      exercise.questions.values.map do |question|
        question.tasks.values.map do |task|
          {value: task.max.to_s.colorize(:light_yellow), :alignment => :center}
        end
      end.flatten
    end.flatten

    student_rows = @results.map do |exam_result|
      student_row = [exam_result.student_id]
      student_row += exercises.values.map do |exercise|
        exercise.questions.values.map do |question|
          question.tasks.values.map do |task|
            task_result = exam_result.result_for(task)
            {value: task_result.task.global_id}
          end
        end.flatten
      end.flatten
      student_row
    end

    exercise_table = table do |t|
      t << [''] + exercise_row
      t.add_separator
      t << [''] + questions_row
      t.add_separator
      t << [''] + task_name_row
      t << [''] + task_value_row
      t.add_separator
      student_rows.each do |student_row|
        t << student_row
      end
    end
    puts exercise_table
  end

end

Exercise = Struct.new(:id, :questions, :weight) do
  EXCERCISE_OPTIONS = [ { name: 'weight', default: 1 } ]
  def self.load(question_id, hash)
    EXCERCISE_OPTIONS.each do |option|
      instance_variable_set("@#{option[:name]}", hash[option[:name].to_s] || option[:default])
    end
    questions = {}
    hash.reject{|k, _| EXCERCISE_OPTIONS.map{|o| o[:name].to_s}.include?(k) }
      .each do |id, questions_hash|
        questions[id] = Question.load(id, questions_hash)
      end
    e = new(question_id, questions)
    questions.values.each{|q| q.exercise = e}
    e
  end

  def tasks
    questions.values.map(&:tasks).map(&:values).flatten
  end

  def read
    questions.values.map(&:read).flatten
  end

end

Question = Struct.new(:id, :tasks) do
  attr_accessor :exercise
  QUESTION_OPTIONS = [
    { name: 'weight', default: 1 },
    { name: 'description', default: 'Frage ohne Beschreibung' }
  ]
  attr_accessor *(QUESTION_OPTIONS.map{|o| o[:name]})

  def self.load(id, hash)
    tasks = {}
    hash.reject{|k, _| QUESTION_OPTIONS.map{|o| o[:name].to_s}.include?(k) }
    .each do |task_id, task_hash|
      tasks[task_id] = Task.load(task_id, task_hash)
    end

    q = Question.new(id, tasks)
    tasks.values.each{|t| t.question = q}
    QUESTION_OPTIONS.each do |option|
      q.instance_variable_set("@#{option[:name]}", hash[option[:name].to_s] || option[:default])
    end
    q
  end

  def read
    puts " ---- #{description} ---- "
    tasks.values.map(&:read)
  end
end

class StudentCancelledException < RuntimeError; end
class OverMaxPointsException < RuntimeError; end

Task = Struct.new(:id, :max) do
  attr_accessor :question
  TASK_OPTIONS = [
    { name: 'weight', default: 1 },
    { name: 'max', default: 1 },
    { name: 'description', default: 'Task ohne Beschreibung' }
  ]
  attr_accessor *(TASK_OPTIONS.map{|o| o[:name]})
  def self.load(id, hash)
    new_task = new(id)
    TASK_OPTIONS.each do |option|
      new_task.instance_variable_set("@#{option[:name]}", hash[option[:name].to_s] || option[:default])
    end
    new_task
  end

  def read
    print "#{description}(#{max})"
    begin
      line = Readline::readline("> ")
      raise StudentCancelledException.new if line == 'q'
      integer = Integer(line)
      raise OverMaxPointsException.new("Maximal #{max} Punkte bei dieser Aufgabe") if integer > max
      TaskResult.new(self, integer)
    rescue ArgumentError => e
      puts "Zahl zwischen 0 und #{max}!"
      read
    rescue OverMaxPointsException => e
      puts e.message
      read
    end
  end

  def global_id
    [question.exercise.id, question.id, id].join('-')
  end
end

ExamResult = Struct.new(:student_id, :task_results) do
  attr_accessor :exam
  def print
    task_results.each do |r|
      puts r.to_pair.join(':')
    end
  end

  def results_hash
    @result_hash ||= task_results.inject({}) do |sum, tr|
      sum[tr.task.global_id] = tr.points
      sum
    end
  end

  def to_csv_row
    exam.columns.inject([student_id]) do |sum, column_id|
      sum << results_hash[column_id]
    end
  end

  def result_for(task)
    task_results.find do |task_result|
      task_result.task.global_id == task.global_id
    end
  end
end
TaskResult = Struct.new(:task, :points) do
  def to_pair
    [task.global_id, points]
  end

  def weighted_points
    task.question.max_points
  end
end

class Examinator
  CMDS = [
    {key: 'r', descr: 'Klausurergebnisse', method: :results},
    {key: 'q', descr: 'Beenden', method: :quit },
    {key: 'h', descr: 'Hilfe', method: :printhelp}
  ]

  def initialize(exam_def_file, results_file)
    examHash = YAML.load_file(exam_def_file)
    @exam = Exam.load(examHash)
    @exam.read_results(results_file)
    @result_filename = results_file
  end

  def run
    @running = true
    while @running do
      begin
        input = Readline::readline("Student (oder Kommando):").strip
        cmd = CMDS.find{|c| c[:key] == input}
        if cmd.nil?
          student_id = input
          @exam.read(student_id)
        else
          send(cmd[:method])
        end
      rescue StudentCancelledException
        puts "Aktueller Student verworfen"
      end
    end
    @exam.write(@result_filename)

  end

  def results
    @exam.print_table
  end

  def quit
    @running = false
  end

  def printhelp
    CMDS.each do |cmd|
      puts "#{cmd[:key]} \t - \t #{cmd[:descr]}"
    end
  end

end


exam_def_file, results_file = ARGV
exam_def_file ||= ''
results_file ||= ''
unless exam_def_file.end_with?('.yml') && results_file.end_with?('.csv')
  puts "USAGE: exam EXAM-DEF-YAML RESULTS-CSV"
else
  Examinator.new(exam_def_file, results_file).run
end

