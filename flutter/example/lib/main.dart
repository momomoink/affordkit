// A small app whose controls are in AffordKit's tree: a button, a switch, a text field and a list.
//
// To give a model the tools to see and use it (here the model is called from Dart, in the app):
//
//   final ui = AffordKit.instance.agent();
//   final body = {'model': model, 'messages': messages, 'tools': anthropicTools(ui.tools())};
//   // for each tool_use block in the reply:
//   final result = await anthropicResult(ui, block); // the tool_result block to send back
//
// With the model on a server, answer its requests with AffordKit.instance.answer(request) over your own channel instead.

import 'package:affordkit/affordkit.dart';
import 'package:flutter/material.dart';

void main() {
  // Ops with policy confirm (Delete, below) ask the user first; without this they come back needsConfirm
  AffordKit.instance.confirm = ((call, {node, tool}) async {
    final context = navigatorKey.currentContext;
    if (context == null) return false;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(
          'Let the assistant ${call.toJson()['op'] ?? 'do this'}: ${node?.name ?? tool?.name ?? '?'}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
    return yes ?? false;
  });
  runApp(const ExampleApp());
}

final navigatorKey = GlobalKey<NavigatorState>();

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AffordKit example',
      navigatorKey: navigatorKey,
      // Builds pages off screen for peeks, and takes pictures of the screen
      builder: (context, child) => AffordPreviewHost(child: child!),
      home: const NotesPage(),
    );
  }
}

class NotesPage extends StatefulWidget {
  const NotesPage({super.key});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  final _draft = TextEditingController();
  final _notes = <String>['Buy milk', 'Call Ana'];
  var _pinned = false;

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  void _add() {
    if (_draft.text.trim().isEmpty) return;
    setState(() => _notes.add(_draft.text.trim()));
    _draft.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notes')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _draft,
              decoration: const InputDecoration(labelText: 'New note'),
            ).afford('New note', key: 'notes.draft'),
          ),
          ElevatedButton(
            onPressed: _add,
            child: const Text('Add'),
          ).afford('Add', key: 'notes.add'),
          SwitchListTile(
            title: const Text('Pin new notes'),
            value: _pinned,
            onChanged: (on) => setState(() => _pinned = on),
          ).afford('Pin new notes', key: 'notes.pin'),
          Expanded(
            child: ListView.builder(
              itemCount: _notes.length,
              itemBuilder: (context, i) => ListTile(
                title: Text(_notes[i]),
                trailing: IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: () => setState(() => _notes.removeAt(i)),
                ).afford('Delete', key: 'delete', policy: Policy.confirm),
              ).affordItem('$i', index: i),
            ).affordContainer('Notes', key: 'notes.list', kind: 'list'),
          ),
        ],
      ),
    );
  }
}
