erlc -o ebin src/*.erl
erl -pa ebin -noshell -run make_boot write_scripts

erlc -o ebin test/ringo_cmd.erl
